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
 * migratedb.cpp - load the heap of an older CUBRID database straight into this one.
 *
 * The migration path is  createdb -> schema load -> data load -> index rebuild, and this
 * utility is the data load step; the other three are the operator's.  It skips unloaddb's
 * data dump and loaddb's text parsing entirely:
 *
 *   source volume file --(migratedb_heap)--> record bytes
 *     --> heap_attrinfo_read_dbvalues_without_oid ()   record to values
 *     --> heap_attrinfo_transform_to_disk ()           values to a record of this release
 *     --> locator_insert_force ()                      into the target heap, indexes maintained
 *
 * The middle three are the same calls loaddb's server-side loader makes once it has parsed a
 * line, so only the front is new.
 *
 * Object references need a second pass.  A row's OID column holds the *source* database's OID,
 * which means nothing here, so every class is migrated first -- object columns left NULL --
 * while recording source OID -> target OID, then walked again to fill them in.  That is why
 * references are only resolved in plan mode, where one run sees every class.
 *
 * Standalone only: it opens the source volumes read-only by path and drives the server side
 * in-process.
 */

#include "config.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>

#include "porting.h"
#include "utility.h"
#include "message_catalog.h"
#include "error_manager.h"
#include "migratedb_heap.h"
#include "object_representation.h"
#include "dbtype.h"
#include "db.h"
#include "authenticate.h"
#include "schema_manager.h"
#include "heap_file.h"
#include "locator_sr.h"
#include "locator.h"
#include "replication.h"
#include "btree.h"
#include "object_primitive.h"
#include "object_domain.h"
#include "set_object.h"
#include "work_space.h"
#include "thread_manager.hpp"
#include "log_manager.h"
#include "log_impl.h"
#include "btree_unique.hpp"
#include "record_descriptor.hpp"
#include "lock_manager.h"

// XXX: SHOULD BE THE LAST INCLUDE HEADER
#include "memory_wrapper.hpp"

/* an OID is volid(2) + pageid(4) + slotid(2), so it packs into one 64-bit map key */
static inline uint64_t
oid_key (const OID *oid)
{
  return (((uint64_t) (uint16_t) oid->volid) << 48) | (((uint64_t) (uint32_t) oid->pageid) << 16)
	 | ((uint64_t) (uint16_t) oid->slotid);
}

struct class_plan
{
  std::string classname;
  int src_volid = -1;
  PAGEID src_hpgid = NULL_PAGEID;

  OID class_oid;
  HFID hfid;
  HEAP_CACHE_ATTRINFO attr_info;
  HEAP_SCANCACHE scancache;
  bool scancache_started = false;

  /* value slots that hold an object reference, and the attribute ids behind them */
  std::vector<int> obj_values;
  std::vector<ATTR_ID> obj_attrids;

  bool layout_changed = false;	/* the source laid this class out differently */
  MIGRATE_SRC_LAYOUT src_layout;	/* built only when it did */
  REPR_ID repr_id = NULL_REPRID;	/* the one representation this class can be read with */
  bool has_lob = false;
  bool skipped = false;

  long rows_read = 0;
  long rows_inserted = 0;
  long rows_fixed = 0;
  long read_errors = 0;
  long transform_errors = 0;
  long insert_errors = 0;
  long update_errors = 0;
  long unresolved_refs = 0;
  long old_repr_rows = 0;	/* written under a representation the target no longer has */
  long skipped_bigone = 0;
  long skipped_relocation = 0;
  long relocated_rows = 0;	/* rows that had moved off the page they started on */
};

static MIGRATE_SRC_FORMAT g_src_format;
/* a second page, so a relocation can be followed while the walk still holds its own */
static char *g_scratch_page = NULL;
static THREAD_ENTRY *g_thread_p = NULL;
static std::unordered_map<uint64_t, OID> g_oid_map;
static bool g_remap_oids = false;     /* plan mode resolves references; a single-class run cannot */
static bool g_force = false;
static long g_limit = -1;
static long g_commit_every = 100000;
static bool g_dry_run = false;

/* ------------------------------------------------------------------ scan cache */

static int
start_scancache (class_plan &cp, int op_type)
{
  if (heap_scancache_start_modify (g_thread_p, &cp.scancache, &cp.hfid, &cp.class_oid, op_type, NULL) != NO_ERROR)
    {
      fprintf (stderr, "heap_scancache_start_modify failed: %s\n", db_error_string (3));
      return ER_FAILED;
    }
  cp.scancache.node.classname = NULL;
  cp.scancache_started = true;
  return NO_ERROR;
}

/*
 * The unique index counts a bulk insert accumulates live on the scan cache; they only reach the
 * B+tree root when the scan cache is closed.  Skipping this leaves the data correct but the root
 * statistics at zero, and checkdb reports the class as inconsistent.
 */
static int
stop_scancache (class_plan &cp)
{
  if (!cp.scancache_started)
    {
      return NO_ERROR;
    }

  int error = NO_ERROR;
  if (cp.scancache.m_index_stats != NULL)
    {
      for (const auto &it : cp.scancache.m_index_stats->get_map ())
	{
	  if (!it.second.is_unique ())
	    {
	      fprintf (stderr, "%s: unique violation on an index\n", cp.classname.c_str ());
	      error = ER_FAILED;
	      break;
	    }
	  error = logtb_tran_update_unique_stats (g_thread_p, it.first, it.second, true);
	  if (error != NO_ERROR)
	    {
	      fprintf (stderr, "logtb_tran_update_unique_stats failed: %s\n", db_error_string (3));
	      break;
	    }
	}
    }

  heap_scancache_end_modify (g_thread_p, &cp.scancache);
  cp.scancache_started = false;
  return error;
}

/* ------------------------------------------------------------------ class checks */

/* does this domain, or any element domain under it, hold a reference to an object? */
static bool
domain_holds_object (TP_DOMAIN *domain)
{
  if (domain == NULL)
    {
      return false;
    }

  DB_TYPE t = TP_DOMAIN_TYPE (domain);
  if (t == DB_TYPE_OBJECT)
    {
      return true;
    }
  if (TP_IS_SET_TYPE (t))
    {
      for (TP_DOMAIN *e = domain->setdomain; e != NULL; e = e->next)
	{
	  if (domain_holds_object (e))
	    {
	      return true;
	    }
	}
    }
  return false;
}

/*
 * Read off the target class's representation, before a single row moves:
 *
 *   layout   the 11.4 record is read with the target class's representation, so the two have to
 *            agree on which attributes are stored fixed.  guava moved CHAR, NCHAR and NUMERIC to
 *            variable storage, so a class holding one of them has a different record shape.
 *            Nothing can be done about that here, so such a class is refused.
 *   objects  an OID column, or a collection of objects, carries the source database's OID.
 *            In plan mode the second pass remaps them; a single-class run cannot, so it refuses.
 *   LOB      the locator travels but the external file does not.  Worth a warning, not a refusal.
 */
static bool
check_class (class_plan &cp)
{
  OR_CLASSREP *rep = cp.attr_info.last_classrepr;
  int moved = 0;
  int lobs = 0;

  /* the attr_info is rebuilt per pass, so start from an empty list every time */
  cp.obj_values.clear ();
  cp.obj_attrids.clear ();

  for (int i = 0; i < cp.attr_info.num_values; i++)
    {
      OR_ATTRIBUTE *att = cp.attr_info.values[i].last_attrepr;

      for (int k = 0; k < g_src_format.n_moved_to_variable; k++)
	{
	  if (att->type == g_src_format.moved_to_variable[k])
	    {
	      printf ("  attribute %d type %s is fixed in %s and variable in guava\n",
		      att->id, pr_type_name (att->type), g_src_format.release);
	      moved++;
	      break;
	    }
	}

      if (domain_holds_object (att->domain))
	{
	  cp.obj_values.push_back (i);
	  cp.obj_attrids.push_back (att->id);
	}

      if (att->type == DB_TYPE_BLOB || att->type == DB_TYPE_CLOB)
	{
	  lobs++;
	}
    }
  (void) rep;

  cp.layout_changed = (moved > 0);
  cp.has_lob = (lobs > 0);
  cp.repr_id = cp.attr_info.last_classrepr->id;

  if (lobs > 0)
    {
      printf ("  WARNING: %d LOB attribute(s); the locator is copied but the external file is not\n", lobs);
    }
  if (!cp.obj_values.empty ())
    {
      printf ("  %zu attribute(s) refer to objects; %s\n", cp.obj_values.size (),
	      g_remap_oids ? "a second pass will remap them" : "nothing here remaps them");
    }

  /*
   * The layout is rebuilt for every class, not only the ones that moved: even when the shape is
   * unchanged it is what each record is checked against before being decoded.
   */
  if (migrate_src_layout_build (&g_src_format, &cp.attr_info, &cp.src_layout) != NO_ERROR)
    {
      printf ("  REFUSING: cannot rebuild the source's record shape for this class\n");
      return false;
    }
  if (moved > 0)
    {
      if (cp.src_layout.order_ambiguous)
	{
	  printf ("  %s: two fixed attributes share an alignment and a width, so the order the\n"
		  "  source put them in cannot be recovered from here\n", g_force ? "WARNING" : "REFUSING");
	  if (!g_force)
	    {
	      return false;
	    }
	}
      printf ("  reading with the %s layout: %d fixed (%d bytes), %d variable\n",
	      g_src_format.release, cp.src_layout.n_fixed, cp.src_layout.fixed_length,
	      cp.src_layout.n_variable);
    }
  if (!cp.obj_values.empty () && !g_remap_oids)
    {
      printf ("  %s: source-database OIDs with no remapping (use --plan to migrate every class at once)\n",
	      g_force ? "WARNING" : "REFUSING");
      if (!g_force)
	{
	  return false;
	}
    }
  return true;
}

/* ------------------------------------------------------------------ object value remapping */

/*
 * A reference comes back either as a raw OID or promoted to an object (a workspace MOP),
 * depending on where it sat in the record: a plain attribute keeps the OID, while elements
 * inside a collection arrive promoted.  Both have to be remapped.
 */
static bool
remap_ref_value (DB_VALUE *v, long &unresolved)
{
  if (DB_IS_NULL (v))
    {
      return false;
    }

  DB_TYPE t = DB_VALUE_TYPE (v);
  OID old_oid;
  MOP old_mop = NULL;

  if (t == DB_TYPE_OID)
    {
      COPY_OID (&old_oid, db_get_oid (v));
    }
  else if (t == DB_TYPE_OBJECT)
    {
      old_mop = db_get_object (v);
      if (old_mop == NULL)
	{
	  return false;
	}
      COPY_OID (&old_oid, WS_OID (old_mop));
    }
  else
    {
      return false;
    }

  auto it = g_oid_map.find (oid_key (&old_oid));
  if (it == g_oid_map.end ())
    {
      /* the referenced class was not in the plan, or that row was not migrated */
      unresolved++;
      db_make_null (v);
      return true;
    }

  if (t == DB_TYPE_OID)
    {
      db_make_oid (v, &it->second);
    }
  else
    {
      /* keep the promoted form; ws_mop only interns the identity, it does not fetch */
      MOP new_mop = ws_mop (&it->second, ws_class_mop (old_mop));
      if (new_mop == NULL)
	{
	  unresolved++;
	  db_make_null (v);
	  return true;
	}
      db_make_object (v, new_mop);
    }
  return true;
}

static bool
remap_value (DB_VALUE *v, long &unresolved)
{
  if (DB_IS_NULL (v))
    {
      return false;
    }

  DB_TYPE t = DB_VALUE_TYPE (v);
  if (t == DB_TYPE_OID || t == DB_TYPE_OBJECT)
    {
      return remap_ref_value (v, unresolved);
    }

  if (TP_IS_SET_TYPE (t))
    {
      DB_COLLECTION *col = db_get_set (v);
      if (col == NULL)
	{
	  return false;
	}
      bool changed = false;
      int n = set_size (col);
      for (int i = 0; i < n; i++)
	{
	  DB_VALUE ev;
	  if (set_get_element (col, i, &ev) != NO_ERROR)
	    {
	      continue;
	    }
	  if (remap_ref_value (&ev, unresolved))
	    {
	      if (set_put_element (col, i, &ev) != NO_ERROR)
		{
		  fprintf (stderr, "set_put_element failed: %s\n", db_error_string (3));
		  unresolved++;
		}
	      changed = true;
	    }
	  pr_clear_value (&ev);
	}
      return changed;
    }

  return false;
}

/*
 * Decode one source record into the class's attribute info.  Classes the source laid out the
 * same way go through the engine's own reader; the rest are read with the source's shape.
 */
static int
migrate_read_record (class_plan &cp, char *rec, int reclen, RECDES *src)
{
  /*
   * A record written under some other representation -- a class the source ALTERed -- would
   * decode into plausible-looking nonsense rather than an error, so its shape is checked first.
   */
  if (migrate_src_layout_matches (&cp.src_layout, rec, reclen) != NO_ERROR)
    {
      cp.old_repr_rows++;
      return ER_FAILED;
    }

  if (cp.layout_changed)
    {
      return migrate_src_read_record (&g_src_format, &cp.src_layout, rec, reclen, &cp.attr_info);
    }
  return heap_attrinfo_read_dbvalues_without_oid (g_thread_p, src, &cp.attr_info);
}

/* ------------------------------------------------------------------ pass 1: insert */

static int
pass1_record (char *rec, int reclen, int rec_type, const OID *src_oid, void *arg)
{
  class_plan &cp = * (class_plan *) arg;

  if (rec_type == REC_BIGONE)
    {
      /* the row lives in an overflow file this tool does not read yet */
      cp.skipped_bigone++;
      return NO_ERROR;
    }
  if (rec_type == REC_RELOCATION)
    {
      /*
       * The row outgrew its page and moved; this slot only points at where it went. The row is
       * still known by this slot, which is what src_oid already holds, so only the content comes
       * from the other page.
       */
      if (migrate_heap_follow_relocation (rec, reclen, g_scratch_page, &rec, &reclen) != NO_ERROR)
	{
	  cp.skipped_relocation++;
	  return NO_ERROR;
	}
      cp.relocated_rows++;
    }

  if (g_limit >= 0 && cp.rows_read >= g_limit)
    {
      return NO_ERROR;
    }
  cp.rows_read++;

  RECDES src;
  src.data = rec;
  src.length = reclen;
  src.area_size = -1;
  src.type = (INT16) rec_type;

  heap_attrinfo_clear_dbvalues (&cp.attr_info);
  if (migrate_read_record (cp, rec, reclen, &src) != NO_ERROR)
    {
      if (cp.old_repr_rows == 0 && cp.read_errors < 5)
	{
	  fprintf (stderr, "%s: read failed on row %ld: %s\n",
		   cp.classname.c_str (), cp.rows_read, db_error_string (3));
	}
      if (migrate_src_layout_matches (&cp.src_layout, rec, reclen) == NO_ERROR)
	{
	  cp.read_errors++;
	}
      er_clear ();
      return NO_ERROR;
    }

  /*
   * Object columns go in empty on this pass.  Their targets may not exist yet -- a class can
   * even refer to itself -- and a dangling OID in the target is worse than a NULL: reading it
   * lands on a page the target never reserved.
   */
  for (int i : cp.obj_values)
    {
      pr_clear_value (&cp.attr_info.values[i].dbvalue);
      db_make_null (&cp.attr_info.values[i].dbvalue);
    }

  if (g_dry_run)
    {
      return NO_ERROR;
    }

  record_descriptor new_recdes (cubmem::STANDARD_BLOCK_ALLOCATOR);
  if (heap_attrinfo_transform_to_disk (g_thread_p, &cp.attr_info, NULL, &new_recdes) != S_SUCCESS)
    {
      if (cp.transform_errors < 5)
	{
	  fprintf (stderr, "%s: transform_to_disk failed on row %ld: %s\n",
		   cp.classname.c_str (), cp.rows_read, db_error_string (3));
	}
      cp.transform_errors++;
      er_clear ();
      return NO_ERROR;
    }

  OID new_oid;
  int force_count = 0;
  RECDES out = new_recdes.get_recdes ();
  bool has_bu_lock = (lock_has_lock_on_object (&cp.class_oid, oid_Root_class_oid, BU_LOCK) == 1);

  log_sysop_start (g_thread_p);
  int error = locator_insert_force (g_thread_p, &cp.hfid, &cp.class_oid, &new_oid, &out, true,
				    MULTI_ROW_INSERT, &cp.scancache, &force_count, 0, NULL, NULL,
				    UPDATE_INPLACE_NONE, NULL, has_bu_lock, true, false);
  if (error != NO_ERROR)
    {
      log_sysop_abort (g_thread_p);
      if (cp.insert_errors < 5)
	{
	  fprintf (stderr, "%s: insert failed on row %ld: %s\n",
		   cp.classname.c_str (), cp.rows_read, db_error_string (3));
	}
      cp.insert_errors++;
      er_clear ();
      return NO_ERROR;
    }
  log_sysop_attach_to_outer (g_thread_p);
  cp.rows_inserted++;

  if (g_remap_oids)
    {
      g_oid_map[oid_key (src_oid)] = new_oid;
    }

  if (g_commit_every > 0 && (cp.rows_inserted % g_commit_every) == 0)
    {
      if (stop_scancache (cp) != NO_ERROR)
	{
	  return ER_FAILED;
	}
      db_commit_transaction ();
      if (start_scancache (cp, MULTI_ROW_INSERT) != NO_ERROR)
	{
	  return ER_FAILED;
	}
      printf ("  %s: %ld rows committed\n", cp.classname.c_str (), cp.rows_inserted);
    }

  return NO_ERROR;
}

/* ------------------------------------------------------------------ pass 2: fill references */

static int
pass2_record (char *rec, int reclen, int rec_type, const OID *src_oid, void *arg)
{
  class_plan &cp = * (class_plan *) arg;

  if (rec_type == REC_RELOCATION)
    {
      if (migrate_heap_follow_relocation (rec, reclen, g_scratch_page, &rec, &reclen) != NO_ERROR)
	{
	  return NO_ERROR;
	}
    }
  else if (rec_type != REC_HOME)
    {
      return NO_ERROR;
    }

  auto it = g_oid_map.find (oid_key (src_oid));
  if (it == g_oid_map.end ())
    {
      /* the row was skipped on pass 1 (limit, or a decode error); nothing to fill in */
      return NO_ERROR;
    }
  OID target_oid = it->second;

  RECDES src;
  src.data = rec;
  src.length = reclen;
  src.area_size = -1;
  src.type = (INT16) rec_type;

  heap_attrinfo_clear_dbvalues (&cp.attr_info);
  if (migrate_read_record (cp, rec, reclen, &src) != NO_ERROR)
    {
      cp.read_errors++;
      er_clear ();
      return NO_ERROR;
    }

  bool any = false;
  for (int i : cp.obj_values)
    {
      if (remap_value (&cp.attr_info.values[i].dbvalue, cp.unresolved_refs))
	{
	  any = true;
	}
      /* the record is rebuilt from these values, so mark them as ours either way */
      cp.attr_info.values[i].state = HEAP_WRITTEN_ATTRVALUE;
    }
  if (!any)
    {
      /* every reference in this row was NULL to begin with */
      return NO_ERROR;
    }

  int force_count = 0;
  int error = locator_attribute_info_force (g_thread_p, &cp.hfid, &target_oid, &cp.attr_info,
	      cp.obj_attrids.data (), (int) cp.obj_attrids.size (),
	      LC_FLUSH_UPDATE, SINGLE_ROW_UPDATE, &cp.scancache, &force_count,
	      false, REPL_INFO_TYPE_RBR_NORMAL, DB_NOT_PARTITIONED_CLASS,
	      NULL, NULL, NULL, UPDATE_INPLACE_NONE, NULL, false);
  if (error != NO_ERROR)
    {
      if (cp.update_errors < 5)
	{
	  fprintf (stderr, "%s: reference update failed on %d|%d|%d: %s\n", cp.classname.c_str (),
		   target_oid.volid, target_oid.pageid, target_oid.slotid, db_error_string (3));
	}
      cp.update_errors++;
      er_clear ();
      return NO_ERROR;
    }
  cp.rows_fixed++;
  return NO_ERROR;
}

/* ------------------------------------------------------------------ driver */

static int
open_class (class_plan &cp)
{
  MOP class_mop = db_find_class (cp.classname.c_str ());
  if (class_mop == NULL)
    {
      fprintf (stderr, "no class %s: %s\n", cp.classname.c_str (), db_error_string (3));
      return ER_FAILED;
    }
  COPY_OID (&cp.class_oid, ws_oid (class_mop));

  if (heap_attrinfo_start (g_thread_p, &cp.class_oid, -1, NULL, &cp.attr_info) != NO_ERROR)
    {
      fprintf (stderr, "%s: heap_attrinfo_start failed: %s\n", cp.classname.c_str (), db_error_string (3));
      return ER_FAILED;
    }
  if (heap_get_class_info (g_thread_p, &cp.class_oid, &cp.hfid, NULL, NULL) != NO_ERROR)
    {
      fprintf (stderr, "%s: heap_get_class_info failed: %s\n", cp.classname.c_str (), db_error_string (3));
      return ER_FAILED;
    }
  return NO_ERROR;
}

static int
read_plan (const char *path, std::vector<class_plan> &plan)
{
  FILE *fp = fopen (path, "r");
  if (fp == NULL)
    {
      fprintf (stderr, "cannot open plan %s\n", path);
      return ER_FAILED;
    }

  char line[1024];
  while (fgets (line, sizeof (line), fp) != NULL)
    {
      char name[512];
      int volid, hpgid;
      if (line[0] == '#' || sscanf (line, "%511s %d %d", name, &volid, &hpgid) != 3)
	{
	  continue;
	}
      class_plan cp;
      cp.classname = name;
      cp.src_volid = volid;
      cp.src_hpgid = hpgid;
      plan.push_back (std::move (cp));
    }
  fclose (fp);
  return plan.empty () ? ER_FAILED : NO_ERROR;
}

static void
migratedb_usage (const char *argv0)
{
  const char *exec_name = basename ((char *) argv0);

  fprintf (stderr, msgcat_message (MSGCAT_CATALOG_UTILS, MSGCAT_UTIL_SET_MIGRATEDB, MIGRATEDB_MSG_USAGE), exec_name);
  fprintf (stderr, "verified source releases: %s\n", migrate_src_supported_releases ());
}

int
migratedb (UTIL_FUNCTION_ARG *arg)
{
  UTIL_ARG_MAP *arg_map = arg->arg_map;
  const char *src_db_path;
  const char *target_db;
  const char *plan_path;
  const char *class_name;
  char er_msg_file[PATH_MAX];
  char vinf_path[PATH_MAX];
  std::vector<class_plan> plan;
  int n_args;

  plan_path = utility_get_option_string_value (arg_map, MIGRATEDB_PLAN_S, 0);
  class_name = utility_get_option_string_value (arg_map, MIGRATEDB_CLASS_S, 0);
  g_limit = utility_get_option_int_value (arg_map, MIGRATEDB_LIMIT_S);
  g_commit_every = utility_get_option_int_value (arg_map, MIGRATEDB_COMMIT_EVERY_S);
  g_dry_run = utility_get_option_bool_value (arg_map, MIGRATEDB_DRY_RUN_S);
  g_force = utility_get_option_bool_value (arg_map, MIGRATEDB_FORCE_S);

  n_args = utility_get_option_string_table_size (arg_map);
  if (n_args != 2)
    {
      migratedb_usage (arg->argv0);
      return EXIT_FAILURE;
    }
  src_db_path = utility_get_option_string_value (arg_map, OPTION_STRING_TABLE, 0);
  target_db = utility_get_option_string_value (arg_map, OPTION_STRING_TABLE, 1);
  if (src_db_path == NULL || target_db == NULL || check_database_name (target_db))
    {
      migratedb_usage (arg->argv0);
      return EXIT_FAILURE;
    }

  /*
   * Object references can only be resolved when one run sees every class, so a single-class
   * run refuses them (see check_class ()).
   */
  if (plan_path != NULL)
    {
      if (class_name != NULL)
	{
	  fprintf (stderr, "The --plan and --class options cannot be used together.\n");
	  return EXIT_FAILURE;
	}
      g_remap_oids = true;
      if (read_plan (plan_path, plan) != NO_ERROR)
	{
	  return EXIT_FAILURE;
	}
    }
  else
    {
      if (class_name == NULL)
	{
	  migratedb_usage (arg->argv0);
	  return EXIT_FAILURE;
	}
      class_plan cp;
      cp.classname = class_name;
      cp.src_volid = utility_get_option_int_value (arg_map, MIGRATEDB_SRC_VOLID_S);
      cp.src_hpgid = utility_get_option_int_value (arg_map, MIGRATEDB_SRC_HPGID_S);
      if (cp.src_hpgid <= 0)
	{
	  fprintf (stderr, "--class needs --src-volid and --src-hpgid from the source diagdb dump.\n");
	  return EXIT_FAILURE;
	}
      plan.push_back (std::move (cp));
    }

  /* error message log file */
  snprintf (er_msg_file, sizeof (er_msg_file) - 1, "%s_%s.err", target_db, arg->command_name);
  er_init (er_msg_file, ER_NEVER_EXIT);

  /* the source release and page size come out of the source database itself */
  if (migrate_src_detect (src_db_path, &g_src_format) != NO_ERROR)
    {
      return EXIT_FAILURE;
    }
  g_scratch_page = (char *) malloc (g_src_format.io_page_size);
  if (g_scratch_page == NULL)
    {
      return EXIT_FAILURE;
    }

  printf ("source: release %s (compatibility %.1f), page %d bytes\n",
	  g_src_format.release, g_src_format.compatibility, g_src_format.io_page_size);


  snprintf (vinf_path, sizeof (vinf_path), "%s_vinf", src_db_path);
  if (migrate_heap_open (vinf_path, &g_src_format) != NO_ERROR)
    {
      return EXIT_FAILURE;
    }

  AU_DISABLE_PASSWORDS ();
  db_set_client_type (DB_CLIENT_TYPE_ADMIN_UTILITY);
  if (db_login ("DBA", NULL) != NO_ERROR || db_restart (arg->command_name, TRUE, target_db) != NO_ERROR)
    {
      fprintf (stderr, "cannot boot %s: %s\n", target_db, db_error_string (3));
      return EXIT_FAILURE;
    }
  g_thread_p = thread_get_thread_entry_info ();

  struct timeval t0, t1;
  gettimeofday (&t0, NULL);

  /* ---- pass 1: every class, object columns left NULL ---- */
  printf ("=== pass 1: rows ===\n");
  for (class_plan &cp : plan)
    {
      printf ("%s (11.4 heap %d|%d)\n", cp.classname.c_str (), cp.src_volid, cp.src_hpgid);
      if (open_class (cp) != NO_ERROR)
	{
	  cp.skipped = true;
	  continue;
	}
      if (!check_class (cp))
	{
	  cp.skipped = true;
	  heap_attrinfo_end (g_thread_p, &cp.attr_info);
	  continue;
	}
      if (!g_dry_run && start_scancache (cp, MULTI_ROW_INSERT) != NO_ERROR)
	{
	  cp.skipped = true;
	  heap_attrinfo_end (g_thread_p, &cp.attr_info);
	  continue;
	}

      MIGRATE_HEAP_STATS stats;
      migrate_heap_walk (cp.src_volid, cp.src_hpgid, pass1_record, &cp, &stats);
      stop_scancache (cp);
      heap_attrinfo_end (g_thread_p, &cp.attr_info);
      printf ("  read %ld, inserted %ld (BIGONE %ld, RELOC %ld skipped)\n",
	      cp.rows_read, cp.rows_inserted, cp.skipped_bigone, cp.skipped_relocation);
      if (cp.old_repr_rows > 0)
	{
	  printf ("  %ld row(s) were written under an older representation and were not read\n",
		  cp.old_repr_rows);
	}
    }
  if (!g_dry_run)
    {
      db_commit_transaction ();
    }

  /* ---- pass 2: fill in the references now that every target OID is known ---- */
  if (g_remap_oids && !g_dry_run)
    {
      printf ("\n=== pass 2: object references (%zu OIDs mapped) ===\n", g_oid_map.size ());
      for (class_plan &cp : plan)
	{
	  if (cp.skipped || cp.obj_values.empty ())
	    {
	      continue;
	    }
	  if (open_class (cp) != NO_ERROR)
	    {
	      continue;
	    }
	  (void) check_class (cp);	/* refills obj_values against the fresh attr_info */
	  if (locator_start_force_scan_cache (g_thread_p, &cp.scancache, &cp.hfid, &cp.class_oid, SINGLE_ROW_UPDATE)
	      != NO_ERROR)
	    {
	      fprintf (stderr, "%s: locator_start_force_scan_cache failed: %s\n",
		       cp.classname.c_str (), db_error_string (3));
	      heap_attrinfo_end (g_thread_p, &cp.attr_info);
	      continue;
	    }

	  MIGRATE_HEAP_STATS stats;
	  migrate_heap_walk (cp.src_volid, cp.src_hpgid, pass2_record, &cp, &stats);

	  locator_end_force_scan_cache (g_thread_p, &cp.scancache);
	  heap_attrinfo_end (g_thread_p, &cp.attr_info);
	  printf ("%s: %ld rows filled, %ld unresolved, %ld update errors\n",
		  cp.classname.c_str (), cp.rows_fixed, cp.unresolved_refs, cp.update_errors);
	}
      db_commit_transaction ();
    }

  gettimeofday (&t1, NULL);
  double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) / 1e6;

  /* ---- report ---- */
  long t_read = 0, t_ins = 0, t_fix = 0, t_err = 0, t_unres = 0, t_big = 0, t_rel = 0, n_skipped = 0;
  long t_oldrepr = 0, t_reloc = 0;
  for (const class_plan &cp : plan)
    {
      t_read += cp.rows_read;
      t_ins += cp.rows_inserted;
      t_fix += cp.rows_fixed;
      t_err += cp.read_errors + cp.transform_errors + cp.insert_errors + cp.update_errors;
      t_unres += cp.unresolved_refs;
      t_big += cp.skipped_bigone;
      t_rel += cp.skipped_relocation;
      t_reloc += cp.relocated_rows;
      n_skipped += cp.skipped ? 1 : 0;
      t_oldrepr += cp.old_repr_rows;
    }

  printf ("\n--- totals ---\n");
  printf ("classes           : %zu (%ld refused or missing)\n", plan.size (), n_skipped);
  printf ("rows read         : %ld\n", t_read);
  printf ("rows inserted     : %ld\n", t_ins);
  printf ("rows with refs set: %ld\n", t_fix);
  printf ("unresolved refs   : %ld\n", t_unres);
  printf ("errors            : %ld\n", t_err);
  printf ("other record shape : %ld\n", t_oldrepr);
  printf ("skipped REC_BIGONE: %ld\n", t_big);
  printf ("relocated rows    : %ld followed, %ld unreadable\n", t_reloc, t_rel);
  printf ("elapsed           : %.3f s\n", secs);

  db_shutdown ();
  migrate_heap_close ();

  bool ok = (t_err == 0 && t_unres == 0 && n_skipped == 0 && t_oldrepr == 0 && t_big == 0 && t_rel == 0);
  printf ("\n%s\n", ok ? "OK" : "INCOMPLETE");
  return ok ? 0 : 1;
}
