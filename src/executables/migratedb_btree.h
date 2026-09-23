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

/*
 * migratedb_btree.h - walk a B-tree of the source database, straight off its pages
 *
 * The source's indexes already hold every key in order.  Walking one gives the keys and the
 * objects under them without scanning the heap or sorting, which is what building the same
 * index again in the target would otherwise spend its time on.  This reads only; what the
 * keys are used for is the caller's business.
 */

#ifndef _MIGRATEDB_BTREE_H_
#define _MIGRATEDB_BTREE_H_

#include "config.h"

#include "storage_common.h"
#include "dbtype_def.h"
#include "btree.h"
#include "thread_compat.hpp"

typedef struct migrate_btree_stats MIGRATE_BTREE_STATS;
struct migrate_btree_stats
{
  /* what the root header says */
  INT64 root_num_keys;
  INT64 root_num_oids;
  INT64 root_num_nulls;
  int unique_pk;
  int deduplicate_key_idx;	/* -1 when the index has no deduplicate key column */
  int levels;			/* the leaf level is 1 */
  char key_type[64];

  /* what the walk found */
  long leaf_pages;
  long keys;
  long oids;
  long overflow_oid_pages;
  long fence_records;
  long prefix_pages;		/* leaf pages whose keys share a common prefix taken from the fence */
  long overflow_keys;		/* keys too long for a leaf page: not read, see migrate_btree_walk () */
  long out_of_order;		/* keys not above the one before them, by this release's comparison */
  long oids_insid_not_all_visible;	/* the insert is not yet visible to everyone */
  long oids_delid_valid;	/* deleted, and vacuum has not removed it yet */
  long oids_with_class_oid;	/* objects of a class below the index's own: a unique index over a hierarchy */
};

/*
 * Called once per object: its key, the object's source OID, its class OID for a unique index
 * over a hierarchy (else NULL OID), and the MVCC ids the index keeps for it.
 */
typedef int (*MIGRATE_BTREE_OBJECT_FN) (const DB_VALUE * key, const OID * oid, const OID * class_oid,
					const BTREE_MVCC_INFO * mvcc_info, void *arg);

/*
 * Walk the source B-tree whose root is btid, leftmost leaf to rightmost, calling fn for every
 * object under every key.  A key kept in an overflow page is counted and skipped -- its pages are
 * not read -- so a caller that needs every key has to check stats->overflow_keys.
 */
extern int migrate_btree_walk (THREAD_ENTRY * thread_p, const BTID * btid, int io_page_size,
			       MIGRATE_BTREE_OBJECT_FN fn, void *arg, MIGRATE_BTREE_STATS * stats);

#endif /* _MIGRATEDB_BTREE_H_ */
