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
 * migratedb_heap.h - walk a heap file of an older CUBRID database, with guava code.
 *
 * Read-only, and it does not boot anything: the volume files are opened directly and the
 * pages are interpreted with guava's slotted-page structs.  The file manager is not usable
 * here because FILE_HEADER differs between releases, so the pages are reached through
 * HEAP_CHAIN.next_vpid instead.
 *
 * Everything that depends on which release wrote the volume lives in MIGRATE_SRC_FORMAT, so
 * adding a source release means adding a row to migrate_Known_formats[] and verifying it --
 * not touching the walk.
 */

#ifndef _MIGRATEDB_HEAP_H_
#define _MIGRATEDB_HEAP_H_

#include "config.h"

#include "storage_common.h"
#include "slotted_page.h"
#include "file_io.h"
#include "dbtype_def.h"
#include "release_string.h"
#include "object_domain.h"
#include "heap_attrinfo.h"

#define MIGRATE_HEAP_HEADER_AND_CHAIN_SLOTID 0

/*
 * What this tool needs to know about the release that wrote the source volumes.
 * Values are per release and must be verified against that release's headers before being added.
 */
typedef struct migrate_src_format MIGRATE_SRC_FORMAT;
struct migrate_src_format
{
  char release[REL_MAX_RELEASE_LENGTH + 1];	/* "11.4.5", read from the source log header */
  float compatibility;		/* 11.4 -- what the table below is keyed by */

  int io_page_size;		/* page size on disk, read from the source log header */
  int log_page_size;

  /*
   * A disk page is FILEIO_PAGE:
   *   [ reserved prefix ][ user page area = DB_PAGESIZE ][ watermark ]
   * PAGE_PTR points past the prefix, and slots grow backwards from the end of the user area.
   */
  int page_prefix_size;		/* sizeof (FILEIO_PAGE_RESERVED) in that release */
  int page_reserved_size;	/* prefix + watermark; DB_PAGESIZE = io_page_size - this */

  /* offset of HEAP_HDR_STATS.next_vpid, which opens the page chain */
  int hdr_next_vpid_offset;

  /*
   * Attributes this release stores fixed that this one stores variable.  A class holding one of
   * them has a different record shape in the two, so it cannot be read with the target class's
   * representation as it stands; migrate_src_layout_build () rebuilds the source's shape instead.
   */
  const DB_TYPE *moved_to_variable;
  int n_moved_to_variable;

  /* on-disk size of a fixed NUMERIC in that release; this one uses a different constant */
  int numeric_disk_size;
};

/*
 * The source's shape for one attribute, expressed against the target class's attribute of the
 * same id: the domain comes from the target (same DDL, same domain), the placement from the source.
 */
typedef struct migrate_src_attr MIGRATE_SRC_ATTR;
struct migrate_src_attr
{
  ATTR_ID id;
  int def_order;		/* the column's place in the class definition */
  int value_index;		/* index into HEAP_CACHE_ATTRINFO::values */
  TP_DOMAIN *domain;
  bool is_fixed;		/* in the source */
  int location;			/* byte offset inside the fixed block, or index into the variable table */
  int disk_size;		/* fixed only: size in the source's encoding */
};

typedef struct migrate_src_layout MIGRATE_SRC_LAYOUT;
struct migrate_src_layout
{
  int n_attrs;
  int n_fixed;
  int n_variable;
  int fixed_length;
  /*
   * Two fixed attributes of the same alignment and width leave the source's order unknowable, so
   * a layout that has to be rebuilt cannot be trusted; the widths and counts still can be.
   */
  bool order_ambiguous;
  MIGRATE_SRC_ATTR *attrs;	/* source storage order: the fixed block first, then the variable ones */
};

/*
 * Both are written to the page as a raw struct image, so native layout applies -- not the
 * OR_* encoding.  HEAP_CHAIN has been identical so far; if a release differs, the difference
 * belongs in MIGRATE_SRC_FORMAT.
 */
typedef struct migrate_heap_chain MIGRATE_HEAP_CHAIN;
struct migrate_heap_chain
{
  OID class_oid;
  VPID prev_vpid;
  VPID next_vpid;
  MVCCID max_mvccid;
  INT32 flags;
};

typedef struct migrate_heap_stats MIGRATE_HEAP_STATS;
struct migrate_heap_stats
{
  long pages;
  long rec_home;
  long rec_bigone;
  long rec_relocation;
  long rec_newhome;
  long rec_other;
};

/*
 * Called once per record that describes a row; rec_type is REC_HOME / REC_BIGONE / ...
 * src_oid is where the record sits in the source database, which is what its own rows are
 * referred to by, so a caller that remaps references needs it.
 */
typedef int (*MIGRATE_HEAP_RECORD_FN) (char *rec, int reclen, int rec_type, const OID * src_oid, void *arg);

/*
 * Read the source release and page sizes out of <db_path_prefix>_lgat's log header and fill in
 * the matching row of migrate_Known_formats[].  Fails if the release is not one we have verified.
 */
extern int migrate_src_detect (const char *db_path_prefix, MIGRATE_SRC_FORMAT * fmt);
extern const char *migrate_src_supported_releases (void);

extern int migrate_heap_open (const char *vinf_path, const MIGRATE_SRC_FORMAT * fmt);
extern void migrate_heap_close (void);
extern int migrate_heap_db_page_size (void);

/* reads the page into caller-provided IO-page-sized storage; returns the user page area */
extern char *migrate_heap_read_page (int volid, PAGEID pageid, char *iopage);
extern SPAGE_SLOT *migrate_heap_page_slot (char *page, PGSLOTID slot_id);

/*
 * Walk the heap whose header page is <hfid_volid, hpgid>, calling fn for every record that
 * is not the header or chain record.  Stops and returns the callback's error if it returns
 * anything but NO_ERROR.
 */
extern int migrate_heap_walk (int hfid_volid, PAGEID hpgid, MIGRATE_HEAP_RECORD_FN fn, void *arg,
			      MIGRATE_HEAP_STATS * stats);

/*
 * Rebuild the source's record shape for a class from the target class's representation.  What
 * moved between fixed and variable storage is the only thing that differs, and the order inside
 * each group follows rules the two releases share, so the shape can be computed rather than
 * carried in from outside.  Returns ER_FAILED if the class holds something this cannot place.
 */
extern int migrate_src_layout_build (const MIGRATE_SRC_FORMAT * fmt, HEAP_CACHE_ATTRINFO * attr_info,
				     MIGRATE_SRC_LAYOUT * layout);
extern void migrate_src_layout_free (MIGRATE_SRC_LAYOUT * layout);

/*
 * Does the record have the shape the layout describes? Representation ids are not comparable
 * across databases, so the shape is what tells a readable record from one written under some
 * other representation.
 */
extern int migrate_src_layout_matches (const MIGRATE_SRC_LAYOUT * layout, char *rec, int reclen);

/* Decode a source record into the attribute info, in place of heap_attrinfo_read_dbvalues_without_oid (). */
extern int migrate_src_read_record (const MIGRATE_SRC_FORMAT * fmt, const MIGRATE_SRC_LAYOUT * layout,
				    char *rec, int reclen, HEAP_CACHE_ATTRINFO * attr_info);

#endif /* _MIGRATEDB_HEAP_H_ */
