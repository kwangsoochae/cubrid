/*
 * Copyright 2008 Search Solution Corporation
 * Copyright 2016 CUBRID Corporation
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#include "migratedb_btree.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "error_code.h"
#include "migratedb_heap.h"
#include "btree_load.h"
#include "slotted_page.h"
#include "object_representation.h"
#include "object_primitive.h"
#include "object_domain.h"

// XXX: SHOULD BE THE LAST INCLUDE HEADER
#include "memory_wrapper.hpp"

/*
 * The pages come straight out of the source's files, not through the page buffer, so only the
 * engine's readers that stay off the page buffer are used here: spage_get_record (), a type's
 * index_readval (), btree_record_process_objects (), pr_midxkey_add_prefix () and
 * btree_compare_key ().  btree_get_node_header (), btree_get_root_header () and
 * btree_read_record () check the page against the page buffer in a debug build, and
 * btree_read_record () would fetch an overflow key from the target's own files, so the few
 * lines they spend on a leaf record are spelled out below instead.
 *
 * The layout they read -- BTREE_ROOT_HEADER, BTREE_NODE_HEADER, BTREE_OVERFLOW_HEADER, the leaf
 * record and its flags -- was compared between 11.4 and this release and is the same.  The flags
 * are private to btree.c, so they are repeated here.
 */
#define MIGRATE_BT_RECORD_OVERFLOW_OIDS ((short) 0x2000)	/* BTREE_LEAF_RECORD_OVERFLOW_OIDS */
#define MIGRATE_BT_RECORD_OVERFLOW_KEY ((short) 0x4000)	/* BTREE_LEAF_RECORD_OVERFLOW_KEY */
#define MIGRATE_BT_RECORD_CLASS_OID ((short) 0x8000)	/* BTREE_LEAF_RECORD_CLASS_OID */
#define MIGRATE_BT_OID_HAS_INSID ((short) 0x4000)	/* BTREE_OID_HAS_MVCC_INSID */
#define MIGRATE_BT_OID_HAS_DELID ((short) 0x8000)	/* BTREE_OID_HAS_MVCC_DELID */
#define MIGRATE_BT_HEADER_SLOT 0
#define MIGRATE_BT_FIRST_SLOT 1

/* the record flags ride on the first object's slotid, the MVCC flags on its volid */
static bool
migrate_btree_record_flagged (const RECDES *rec, short flag)
{
  return (OR_GET_SHORT (rec->data + OR_OID_SLOTID) & flag) == flag;
}

static bool
migrate_btree_object_flagged (const RECDES *rec, short flag)
{
  return (OR_GET_SHORT (rec->data + OR_OID_VOLID) & flag) == flag;
}

static int
migrate_btree_peek (THREAD_ENTRY *thread_p, PAGE_PTR page, PGSLOTID slot, RECDES *rec)
{
  return spage_get_record (thread_p, page, slot, rec, PEEK) == S_SUCCESS ? NO_ERROR : ER_FAILED;
}

/*
 * The key of a leaf record whose key is on the page, and the offset just past it -- which is where
 * the objects after the first one start.  What btree_read_record_without_decompression () does.
 */
static int
migrate_btree_read_leaf_key (BTID_INT *btid_int, RECDES *rec, DB_VALUE *key, int *after_key)
{
  OR_BUF buf;
  int rc;

  or_init (&buf, rec->data, rec->length);
  rc = or_advance (&buf, OR_OID_SIZE);
  if (rc == NO_ERROR && BTREE_IS_UNIQUE (btid_int->unique_pk)
      && migrate_btree_record_flagged (rec, MIGRATE_BT_RECORD_CLASS_OID))
    {
      rc = or_advance (&buf, OR_OID_SIZE);
    }
  if (rc == NO_ERROR && migrate_btree_object_flagged (rec, MIGRATE_BT_OID_HAS_INSID))
    {
      rc = or_advance (&buf, OR_MVCCID_SIZE);
    }
  if (rc == NO_ERROR && migrate_btree_object_flagged (rec, MIGRATE_BT_OID_HAS_DELID))
    {
      rc = or_advance (&buf, OR_MVCCID_SIZE);
    }
  if (rc != NO_ERROR)
    {
      return rc;
    }

  rc = btid_int->key_type->type->index_readval (&buf, key, btid_int->key_type, -1, true, NULL, 0);
  if (rc != NO_ERROR)
    {
      return rc;
    }

  buf.ptr = PTR_ALIGN (buf.ptr, OR_INT_SIZE);
  *after_key = CAST_BUFLEN (buf.ptr - buf.buffer);
  return NO_ERROR;
}

/*
 * The prefix a leaf page's keys leave out, taken from its lower fence key.  Only a MIDXKEY leaf
 * with a common prefix shorter than the key has one -- btree_node_get_common_prefix ().
 */
static int
migrate_btree_page_prefix (THREAD_ENTRY *thread_p, BTID_INT *btid_int, PAGE_PTR page,
			   const BTREE_NODE_HEADER *header, DB_VALUE *fence_key)
{
  if (TP_DOMAIN_TYPE (btid_int->key_type) != DB_TYPE_MIDXKEY || header->node_level != 1
      || header->common_prefix <= 0 || header->common_prefix >= btid_int->key_type->precision)
    {
      return 0;
    }

  RECDES rec;
  int after_key;
  if (migrate_btree_peek (thread_p, page, MIGRATE_BT_FIRST_SLOT, &rec) != NO_ERROR
      || !btree_leaf_record_is_fence (&rec)
      || migrate_btree_read_leaf_key (btid_int, &rec, fence_key, &after_key) != NO_ERROR)
    {
      return ER_FAILED;
    }
  return header->common_prefix;
}

typedef struct migrate_btree_walk_ctx MIGRATE_BTREE_WALK_CTX;
struct migrate_btree_walk_ctx
{
  const DB_VALUE *key;
  MIGRATE_BTREE_OBJECT_FN fn;
  void *arg;
  MIGRATE_BTREE_STATS *stats;
};

static int
migrate_btree_object (THREAD_ENTRY *thread_p, BTID_INT *btid_int, RECDES *record, char *object_ptr, OID *oid,
		      OID *class_oid, BTREE_MVCC_INFO *mvcc_info, bool *stop, void *args)
{
  MIGRATE_BTREE_WALK_CTX *ctx = (MIGRATE_BTREE_WALK_CTX *) args;

  /*
   * Judge by the values, not the flags: an object in an overflow page always carries both ids
   * (BTREE_OBJECT_FIXED_SIZE), set to "all visible" and "none" when there is nothing to say.
   */
  ctx->stats->oids++;
  if ((mvcc_info->flags & MIGRATE_BT_OID_HAS_INSID) != 0 && MVCCID_IS_NOT_ALL_VISIBLE (mvcc_info->insert_mvccid))
    {
      ctx->stats->oids_insid_not_all_visible++;
    }
  if ((mvcc_info->flags & MIGRATE_BT_OID_HAS_DELID) != 0 && mvcc_info->delete_mvccid != MVCCID_NULL)
    {
      ctx->stats->oids_delid_valid++;
    }
  /* every object gets a class back from the reader; one below the index's own class is the hierarchy case */
  if (class_oid != NULL && !OID_ISNULL (class_oid) && !OID_EQ (class_oid, &btid_int->topclass_oid))
    {
      ctx->stats->oids_with_class_oid++;
    }
  return ctx->fn != NULL ? ctx->fn (ctx->key, oid, class_oid, mvcc_info, ctx->arg) : NO_ERROR;
}

/* the objects that did not fit in the leaf record, along the chain of overflow pages */
static int
migrate_btree_overflow_objects (THREAD_ENTRY *thread_p, BTID_INT *btid_int, const RECDES *leaf_rec,
				char *ovf_buf, MIGRATE_BTREE_WALK_CTX *ctx)
{
  OR_BUF buf;
  VPID vpid;
  int rc = NO_ERROR;

  /* the link is the last thing in the leaf record: btree_leaf_get_vpid_for_overflow_oids () */
  or_init (&buf, leaf_rec->data + leaf_rec->length - DISK_VPID_ALIGNED_SIZE, DISK_VPID_SIZE);
  vpid.pageid = or_get_int (&buf, &rc);
  if (rc == NO_ERROR)
    {
      vpid.volid = or_get_short (&buf, &rc);
    }

  while (rc == NO_ERROR && !VPID_ISNULL (&vpid))
    {
      PAGE_PTR page = (PAGE_PTR) migrate_heap_read_page (vpid.volid, vpid.pageid, ovf_buf);
      RECDES hdr, rec;
      bool stop = false;

      if (page == NULL || migrate_btree_peek (thread_p, page, MIGRATE_BT_HEADER_SLOT, &hdr) != NO_ERROR
	  || migrate_btree_peek (thread_p, page, MIGRATE_BT_FIRST_SLOT, &rec) != NO_ERROR)
	{
	  return ER_FAILED;
	}
      ctx->stats->overflow_oid_pages++;
      vpid = ((BTREE_OVERFLOW_HEADER *) hdr.data)->next_vpid;
      rc = btree_record_process_objects (thread_p, btid_int, BTREE_OVERFLOW_NODE, &rec, 0, &stop,
					 migrate_btree_object, ctx);
    }
  return rc;
}

int
migrate_btree_walk (THREAD_ENTRY *thread_p, const BTID *btid, int io_page_size, MIGRATE_BTREE_OBJECT_FN fn,
		    void *arg, MIGRATE_BTREE_STATS *stats)
{
  BTID sys_btid = *btid;
  BTID_INT btid_int;
  RECDES rec;
  VPID vpid;
  DB_VALUE key, prev_key, fence_key;
  bool have_prev = false;
  int error = ER_FAILED;

  memset (stats, 0, sizeof (*stats));
  stats->deduplicate_key_idx = -1;
  memset (&btid_int, 0, sizeof (btid_int));
  btid_int.sys_btid = &sys_btid;
  db_make_null (&key);
  db_make_null (&prev_key);
  db_make_null (&fence_key);

  char *node_buf = (char *) malloc (io_page_size);
  char *leaf_buf = (char *) malloc (io_page_size);
  char *ovf_buf = (char *) malloc (io_page_size);
  if (node_buf == NULL || leaf_buf == NULL || ovf_buf == NULL)
    {
      goto end;
    }

  /* the root: the key domain and what the index says about itself */
  {
    PAGE_PTR root = (PAGE_PTR) migrate_heap_read_page (btid->vfid.volid, btid->root_pageid, node_buf);
    if (root == NULL || migrate_btree_peek (thread_p, root, MIGRATE_BT_HEADER_SLOT, &rec) != NO_ERROR)
      {
	fprintf (stderr, "cannot read the root of index %d|%d|%d\n", btid->vfid.volid, btid->vfid.fileid,
		 btid->root_pageid);
	goto end;
      }
    BTREE_ROOT_HEADER *root_header = (BTREE_ROOT_HEADER *) rec.data;
    if (btree_glean_root_header_info (thread_p, root_header, &btid_int, true) != NO_ERROR || btid_int.key_type == NULL)
      {
	fprintf (stderr, "cannot read the key type of index %d|%d|%d\n", btid->vfid.volid, btid->vfid.fileid,
		 btid->root_pageid);
	goto end;
      }
    stats->root_num_keys = root_header->num_keys;
    stats->root_num_oids = root_header->num_oids;
    stats->root_num_nulls = root_header->num_nulls;
    stats->unique_pk = root_header->unique_pk;
    stats->deduplicate_key_idx = btid_int.deduplicate_key_idx;
    stats->levels = root_header->node.node_level;
    snprintf (stats->key_type, sizeof (stats->key_type), "%s", pr_type_name (TP_DOMAIN_TYPE (btid_int.key_type)));

    /* down the leftmost edge: the first record of a non-leaf node points at its leftmost child */
    PAGE_PTR page = root;
    const BTREE_NODE_HEADER *header = &root_header->node;
    vpid.volid = btid->vfid.volid;
    vpid.pageid = btid->root_pageid;
    while (header->node_level > 1)
      {
	if (migrate_btree_peek (thread_p, page, MIGRATE_BT_FIRST_SLOT, &rec) != NO_ERROR)
	  {
	    goto end;
	  }
	/* NON_LEAF_REC: the child's pageid and volid lead the record */
	vpid.pageid = OR_GET_INT (rec.data);
	vpid.volid = OR_GET_SHORT (rec.data + OR_INT_SIZE);
	page = (PAGE_PTR) migrate_heap_read_page (vpid.volid, vpid.pageid, node_buf);
	if (page == NULL || migrate_btree_peek (thread_p, page, MIGRATE_BT_HEADER_SLOT, &rec) != NO_ERROR)
	  {
	    goto end;
	  }
	header = (BTREE_NODE_HEADER *) rec.data;
      }
  }

  /* along the leaves */
  while (!VPID_ISNULL (&vpid))
    {
      PAGE_PTR page = (PAGE_PTR) migrate_heap_read_page (vpid.volid, vpid.pageid, leaf_buf);
      if (page == NULL || migrate_btree_peek (thread_p, page, MIGRATE_BT_HEADER_SLOT, &rec) != NO_ERROR)
	{
	  goto end;
	}
      const BTREE_NODE_HEADER *header = (BTREE_NODE_HEADER *) rec.data;
      VPID next_vpid = header->next_vpid;
      stats->leaf_pages++;

      pr_clear_value (&fence_key);
      int n_prefix = migrate_btree_page_prefix (thread_p, &btid_int, page, header, &fence_key);
      if (n_prefix < 0)
	{
	  goto end;
	}
      stats->prefix_pages += n_prefix > 0 ? 1 : 0;

      int n_slots = spage_number_of_slots (page);
      for (int slot = MIGRATE_BT_FIRST_SLOT; slot < n_slots; slot++)
	{
	  int after_key;
	  bool stop = false;

	  if (migrate_btree_peek (thread_p, page, slot, &rec) != NO_ERROR)
	    {
	      goto end;
	    }
	  if (btree_leaf_record_is_fence (&rec))
	    {
	      stats->fence_records++;
	      continue;
	    }
	  if (migrate_btree_record_flagged (&rec, MIGRATE_BT_RECORD_OVERFLOW_KEY))
	    {
	      stats->overflow_keys++;
	      continue;
	    }

	  pr_clear_value (&key);
	  if (migrate_btree_read_leaf_key (&btid_int, &rec, &key, &after_key) != NO_ERROR)
	    {
	      fprintf (stderr, "cannot read a key at %d|%d slot %d\n", vpid.volid, vpid.pageid, slot);
	      goto end;
	    }
	  if (n_prefix > 0)
	    {
	      DB_VALUE full;
	      if (pr_midxkey_add_prefix (&full, &fence_key, &key, n_prefix) != NO_ERROR)
		{
		  goto end;
		}
	      pr_clear_value (&key);
	      key = full;
	    }

	  /* the order this release's comparison sees, the same test btree_construct_leafs () makes */
	  if (have_prev && btree_compare_key (&key, &prev_key, btid_int.key_type, 0, 1, NULL) != DB_GT)
	    {
	      stats->out_of_order++;
	    }
	  pr_clear_value (&prev_key);
	  pr_clone_value (&key, &prev_key);
	  have_prev = true;
	  stats->keys++;

	  MIGRATE_BTREE_WALK_CTX ctx = { &key, fn, arg, stats };
	  if (btree_record_process_objects (thread_p, &btid_int, BTREE_LEAF_NODE, &rec, after_key, &stop,
					    migrate_btree_object, &ctx) != NO_ERROR)
	    {
	      goto end;
	    }
	  if (migrate_btree_record_flagged (&rec, MIGRATE_BT_RECORD_OVERFLOW_OIDS)
	      && migrate_btree_overflow_objects (thread_p, &btid_int, &rec, ovf_buf, &ctx) != NO_ERROR)
	    {
	      goto end;
	    }
	}
      vpid = next_vpid;
    }
  error = NO_ERROR;

end:
  pr_clear_value (&key);
  pr_clear_value (&prev_key);
  pr_clear_value (&fence_key);
  free (node_buf);
  free (leaf_buf);
  free (ovf_buf);
  return error;
}
