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

#include "migratedb_heap.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <map>
#include <string>
#include <vector>

#include <cstddef>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "error_code.h"
#include "error_manager.h"
#include "disk_manager.h"
#include "object_representation.h"
#include "object_primitive.h"
#include "intl_support.h"
#include "dbtype.h"
#include "memory_alloc.h"
#include "compressor.hpp"
#include "log_volids.hpp"

#include <cmath>
#include <climits>

// XXX: SHOULD BE THE LAST INCLUDE HEADER
#include "memory_wrapper.hpp"

/*
 * Known source releases.  A row is only here once its on-disk shapes have been checked against
 * that release's headers; an unverified release is refused rather than guessed at.
 *
 * Adding a release means adding a row and checking these against that release's sources.  The
 * ones the row carries:
 *
 *   release, compatibility        release_string.c -- both are read back from the source's log
 *                                 header, so they have to be what that release writes there
 *   io_page_size, log_page_size   also read from the log header; the row records what this was
 *                                 verified against
 *   page_prefix_size              sizeof (FILEIO_PAGE_RESERVED)                      file_io.h
 *   page_reserved_size            that plus sizeof (FILEIO_PAGE_WATERMARK)
 *   hdr_next_vpid_offset          offsetof (HEAP_HDR_STATS, next_vpid)              heap_file.c
 *   moved_to_variable             PR_TYPE::variable_p, per type              object_primitive.c
 *   numeric_disk_size             the size a fixed NUMERIC takes on disk
 *   volheader_boot_hfid_offset    offsetof (DISK_VOLUME_HEADER, boot_hfid)       disk_manager.c
 *   dbparm_rootclass_hfid_offset  offsetof (BOOT_DB_PARM, rootclass_hfid)            boot_sr.c
 *   class_*                       the ORC_* constants               object_representation.h,
 *                                 except class_flag_system: SM_CLASSFLAG_SYSTEM in class_object.h
 *
 * And the shapes the walk reads as raw images, which no row can express -- if one of these
 * differs in a release, the code needs a branch, not a row:
 *
 *   SPAGE_HEADER, SPAGE_SLOT                              slotted_page.h
 *   HEAP_CHAIN                                            heap_file.c
 *   OVERFLOW_FIRST_PART, OVERFLOW_REST_PART               overflow_file.c
 *   VFID, HFID                                            storage_common.h -- copied straight
 *                                                         out of the volume header and the boot
 *                                                         parameter record
 *   the record header and its variable table              OR_* in object_representation.h
 *   the string encoding a class name is written in        object_primitive.c
 *
 * All of the above were compared between 11.4 and this release.  Only two things differed: the
 * types in moved_to_variable, and NUMERIC's size on disk.
 */
static const DB_TYPE mv_11_4[] = { DB_TYPE_CHAR, DB_TYPE_NCHAR_DEPRECATED, DB_TYPE_NUMERIC };

static const MIGRATE_SRC_FORMAT migrate_Known_formats[] =
{
  /*
   * release compat io log prefix reserved next_vpid moved_to_variable n numeric_disk_size
   * boot_hfid rootclass_hfid class_var_att_count class_name_index class_hfid fileid volid pageid
   *
   * 11.4's fixed NUMERIC is DB_NUMERIC_BUF_SIZE, which was 2 * sizeof (double) there and is 17 here.
   */
  {
    "11.4", 11.4f, 0, 0, 32, 40, 16, mv_11_4, (int) (sizeof (mv_11_4) / sizeof (mv_11_4[0])), 16,
    96, 20, 17, 0, 16, 20, 24, 64, 1
  },
};

static const int migrate_Known_format_count =
	(int) (sizeof (migrate_Known_formats) / sizeof (migrate_Known_formats[0]));

static MIGRATE_SRC_FORMAT hp_format;
static int hp_io_page_size = 0;
static int hp_db_page_size = 0;

/* volid -> volume file path, read from the database's _vinf file */
static std::map<int, std::string> hp_volumes;
static std::map<int, int> hp_fds;

/*
 * A backup volume is one stream: a header, then for each file it holds a FILE_START header, the
 * file's content in blocks of bkpagesize bytes -- each tagged with its block number, and LZ4
 * compressed unless that did not pay -- and a FILE_END block, and after the last file END.
 * Opening one walks the stream once and remembers where every block of the data volumes and of
 * the active log is; pages are then read out of those blocks.
 *
 * A full backup holds every page, in blocks of 32.  An incremental one holds, a page to a block,
 * only the pages written since the backup a level below it; so it is read together with the full
 * backup and any levels in between, and a page is taken from the highest level that has it --
 * what restoredb ends up writing, since it restores the highest level first and lets no lower
 * level overwrite a page already restored.
 *
 * FILEIO_BACKUP_HEADER and FILEIO_BACKUP_PAGE come from file_io.h.  The rest file_io.c keeps to
 * itself, so it is spelled out here.  All of it was compared between 11.4 and this release.
 */
#define MIGRATE_BK_HEADER_VERSION 2	/* FILEIO_BACKUP_CURRENT_HEADER_VERSION, the one with zip_method */
#define MIGRATE_BK_HEADER_IO_SIZE ((((sizeof (FILEIO_BACKUP_HEADER) - 1) / 1024) + 1) * 1024)
#define MIGRATE_BK_END_PAGE_ID (-3)
#define MIGRATE_BK_FILE_START_PAGE_ID (-4)
#define MIGRATE_BK_FILE_END_PAGE_ID (-5)
#define MIGRATE_BK_CACHE_SLOTS 8

/* FILEIO_BACKUP_FILE_HEADER */
typedef struct migrate_bk_file_header MIGRATE_BK_FILE_HEADER;
struct migrate_bk_file_header
{
  INT64 nbytes;
  VOLID volid;
  short dummy1;
  int dummy2;
  char vlabel[PATH_MAX];
};

typedef struct migrate_bk_block MIGRATE_BK_BLOCK;
struct migrate_bk_block
{
  off_t offset;			/* of the stored bytes; -1 when the backup does not have the block */
  int length;			/* stored bytes; the backup's node_size means stored as is */
};

typedef struct migrate_bk_file MIGRATE_BK_FILE;
struct migrate_bk_file
{
  INT64 nbytes;
  std::vector<MIGRATE_BK_BLOCK> blocks;	/* by block number */
};

/* one backup volume, one level */
typedef struct migrate_bk_volume MIGRATE_BK_VOLUME;
struct migrate_bk_volume
{
  std::string path;
  int fd;
  FILEIO_BACKUP_HEADER hdr;
  int block_size;		/* bkpagesize */
  int node_size;		/* a block with the page id tags around it */
  bool compressed;
  std::map<int, MIGRATE_BK_FILE> files;
};

typedef struct migrate_bk_cache_slot MIGRATE_BK_CACHE_SLOT;
struct migrate_bk_cache_slot
{
  int level;
  int volid;
  int block;
  char *node;			/* the block as a FILEIO_BACKUP_PAGE image */
};

static std::vector<MIGRATE_BK_VOLUME> hp_bks;	/* by level, the full backup first */
static MIGRATE_BK_CACHE_SLOT hp_bk_cache[MIGRATE_BK_CACHE_SLOTS];
static int hp_bk_cache_next = 0;
static int hp_bk_node_max = 0;	/* the largest node_size: what a cache slot and hp_bk_zip_buf hold */
static char *hp_bk_zip_buf = NULL;

int
migrate_heap_db_page_size (void)
{
  return hp_db_page_size;
}

/*
 * The active log's header carries the release that wrote the database, its compatibility number
 * and the page sizes -- and that prefix has kept the same offsets across the releases checked so
 * far, which is what lets a newer binary read it at all.  Layout up to db_iopagesize:
 *
 *   LOG_HDRPAGE                       16 bytes (log page header, in front of the struct)
 *   magic[CUBRID_MAGIC_MAX_LENGTH]    25 + 3 pad
 *   INT32                              4      (dummy in 11.4, cdc_arv_num_to_keep in guava)
 *   INT64 db_creation                  8
 *   INT64 vol_creation                 8
 *   char db_release[15]                      <- 0x40 from the start of the file
 *   1 pad, float db_compatibility      4
 *   PGLENGTH db_iopagesize             2
 *   PGLENGTH db_logpagesize            2
 */
#define MIGRATE_LOG_HDR_RELEASE_OFFSET 0x40

static float
migrate_release_to_compat (const char *release)
{
  int major = 0, minor = 0;

  if (sscanf (release, "%d.%d", &major, &minor) != 2)
    {
      return 0.0f;
    }
  return (float) major + (float) minor / 10.0f;
}

const char *
migrate_src_supported_releases (void)
{
  static char buf[256];
  buf[0] = '\0';
  for (int i = 0; i < migrate_Known_format_count; i++)
    {
      if (i > 0)
	{
	  strncat (buf, ", ", sizeof (buf) - strlen (buf) - 1);
	}
      strncat (buf, migrate_Known_formats[i].release, sizeof (buf) - strlen (buf) - 1);
    }
  return buf;
}

#define MIGRATE_LOG_HDR_PREFIX_SIZE 128

/* head is the first MIGRATE_LOG_HDR_PREFIX_SIZE bytes of the source's active log */
static int
migrate_src_detect_log_header (const char *head, MIGRATE_SRC_FORMAT *fmt)
{
  char release[REL_MAX_RELEASE_LENGTH + 1];
  memcpy (release, head + MIGRATE_LOG_HDR_RELEASE_OFFSET, REL_MAX_RELEASE_LENGTH);
  release[REL_MAX_RELEASE_LENGTH] = '\0';

  float compat;
  INT16 io_page_size, log_page_size;
  memcpy (&compat, head + MIGRATE_LOG_HDR_RELEASE_OFFSET + REL_MAX_RELEASE_LENGTH + 1, sizeof (compat));
  memcpy (&io_page_size, head + MIGRATE_LOG_HDR_RELEASE_OFFSET + REL_MAX_RELEASE_LENGTH + 1 + 4,
	  sizeof (io_page_size));
  memcpy (&log_page_size, head + MIGRATE_LOG_HDR_RELEASE_OFFSET + REL_MAX_RELEASE_LENGTH + 1 + 6,
	  sizeof (log_page_size));

  /*
   * The release string is the label; the compatibility number is what the table is keyed by,
   * because that is what the engine itself uses to decide format compatibility.  Fall back to
   * the release string when the stored compatibility does not land on a known row exactly --
   * it is a float and 11.4 reads back as 11.399999.
   */
  float want = migrate_release_to_compat (release);
  for (int i = 0; i < migrate_Known_format_count; i++)
    {
      if (fabsf (migrate_Known_formats[i].compatibility - want) < 0.05f)
	{
	  *fmt = migrate_Known_formats[i];
	  snprintf (fmt->release, sizeof (fmt->release), "%s", release);
	  fmt->compatibility = compat;
	  fmt->io_page_size = io_page_size;
	  fmt->log_page_size = log_page_size;
	  return NO_ERROR;
	}
    }

  fprintf (stderr, "source release %s is not one this tool has been verified against (known: %s)\n",
	   release, migrate_src_supported_releases ());
  return ER_FAILED;
}

static void
migrate_heap_set_format (const MIGRATE_SRC_FORMAT *fmt)
{
  hp_format = *fmt;
  hp_io_page_size = fmt->io_page_size;
  hp_db_page_size = fmt->io_page_size - fmt->page_reserved_size;
}

/* ------------------------------------------------------------------ source: the database's volumes */

static int
migrate_vol_open (const char *db_path_prefix, MIGRATE_SRC_FORMAT *fmt)
{
  char path[PATH_MAX];
  snprintf (path, sizeof (path), "%s_lgat", db_path_prefix);

  int fd = open (path, O_RDONLY);
  if (fd < 0)
    {
      fprintf (stderr, "cannot open the source active log %s: %s\n", path, strerror (errno));
      return ER_FAILED;
    }

  char head[MIGRATE_LOG_HDR_PREFIX_SIZE];
  ssize_t n = pread (fd, head, sizeof (head), 0);
  close (fd);
  if (n != (ssize_t) sizeof (head))
    {
      fprintf (stderr, "cannot read the source log header from %s\n", path);
      return ER_FAILED;
    }
  if (migrate_src_detect_log_header (head, fmt) != NO_ERROR)
    {
      return ER_FAILED;
    }

  snprintf (path, sizeof (path), "%s_vinf", db_path_prefix);
  FILE *fp = fopen (path, "r");
  if (fp == NULL)
    {
      fprintf (stderr, "cannot open %s: %s\n", path, strerror (errno));
      return ER_FAILED;
    }

  char line[2048];
  while (fgets (line, sizeof (line), fp) != NULL)
    {
      int volid;
      char vol_path[1024];
      if (sscanf (line, "%d %1023s", &volid, vol_path) == 2 && volid >= 0)
	{
	  hp_volumes[volid] = vol_path;
	}
    }
  fclose (fp);

  migrate_heap_set_format (fmt);
  return NO_ERROR;
}

static int
migrate_vol_fd (int volid)
{
  auto it = hp_fds.find (volid);
  if (it != hp_fds.end ())
    {
      return it->second;
    }

  auto vit = hp_volumes.find (volid);
  if (vit == hp_volumes.end ())
    {
      fprintf (stderr, "no volume for volid %d\n", volid);
      return -1;
    }

  int fd = open (vit->second.c_str (), O_RDONLY);
  if (fd < 0)
    {
      fprintf (stderr, "cannot open %s: %s\n", vit->second.c_str (), strerror (errno));
      return -1;
    }
  hp_fds[volid] = fd;
  return fd;
}

static char *
migrate_vol_read_page (int volid, PAGEID pageid, char *iopage)
{
  int fd = migrate_vol_fd (volid);
  if (fd < 0)
    {
      return NULL;
    }

  ssize_t n = pread (fd, iopage, hp_io_page_size, (off_t) pageid * (off_t) hp_io_page_size);
  if (n != hp_io_page_size)
    {
      fprintf (stderr, "short read at %d|%d: %zd (%s)\n", volid, pageid, n, strerror (errno));
      return NULL;
    }
  return iopage;
}

/* ------------------------------------------------------------------ source: backup volumes */

static bool
migrate_bk_pread (const MIGRATE_BK_VOLUME *bk, off_t offset, void *buf, size_t size)
{
  char *p = (char *) buf;

  while (size > 0)
    {
      ssize_t n = pread (bk->fd, p, size, offset);
      if (n < 0 && errno == EINTR)
	{
	  continue;
	}
      if (n <= 0)
	{
	  return false;
	}
      p += n;
      offset += n;
      size -= n;
    }
  return true;
}

/* bring a block's stored bytes back to its FILEIO_BACKUP_PAGE image */
static int
migrate_bk_load_block (const MIGRATE_BK_VOLUME *bk, const MIGRATE_BK_BLOCK *blk, char *node)
{
  if (blk->length == bk->node_size)
    {
      return migrate_bk_pread (bk, blk->offset, node, bk->node_size) ? NO_ERROR : ER_FAILED;
    }

  if (!migrate_bk_pread (bk, blk->offset, hp_bk_zip_buf, blk->length))
    {
      return ER_FAILED;
    }
  // *INDENT-OFF*
  int n = cubcompress::decompress<cubcompress::LZ4> (hp_bk_zip_buf, blk->length, node, bk->node_size);
  // *INDENT-ON*
  return n == bk->node_size ? NO_ERROR : ER_FAILED;
}

/*
 * The block number a block carries, taken from both of its copies -- one in front of the content,
 * one behind it -- which have to agree.  A block stored as is gives them up without being read
 * whole; a compressed one has to be decompressed first.
 */
static int
migrate_bk_block_id (const MIGRATE_BK_VOLUME *bk, const MIGRATE_BK_BLOCK *blk, char *node, PAGEID *id)
{
  const off_t dup_offset = offsetof (FILEIO_BACKUP_PAGE, iopage) + bk->block_size;
  PAGEID dup;

  if (blk->length == bk->node_size)
    {
      if (!migrate_bk_pread (bk, blk->offset, id, sizeof (*id))
	  || !migrate_bk_pread (bk, blk->offset + dup_offset, &dup, sizeof (dup)))
	{
	  return ER_FAILED;
	}
    }
  else
    {
      if (migrate_bk_load_block (bk, blk, node) != NO_ERROR)
	{
	  return ER_FAILED;
	}
      *id = ((FILEIO_BACKUP_PAGE *) node)->iopageid;
      memcpy (&dup, node + dup_offset, sizeof (dup));
    }
  return *id == dup ? NO_ERROR : ER_FAILED;
}

/*
 * One file of the stream, from just after its FILE_START header through its FILE_END block.
 * The blocks are placed by the number they carry, not by where they come: an incremental backup
 * leaves out the pages that did not change, so the position says nothing about the page.
 */
static int
migrate_bk_scan_file (const MIGRATE_BK_VOLUME *bk, off_t *pos, MIGRATE_BK_FILE *file, char *node)
{
  for (;;)
    {
      MIGRATE_BK_BLOCK blk;

      if (bk->compressed)
	{
	  int length;
	  if (!migrate_bk_pread (bk, *pos, &length, sizeof (length)) || length <= 0 || length > bk->node_size)
	    {
	      return ER_FAILED;
	    }
	  blk.offset = *pos + (off_t) sizeof (length);
	  blk.length = length;
	}
      else
	{
	  blk.offset = *pos;
	  blk.length = bk->node_size;
	}
      *pos = blk.offset + blk.length;

      PAGEID id;
      if (migrate_bk_block_id (bk, &blk, node, &id) != NO_ERROR)
	{
	  return ER_FAILED;
	}
      if (id == MIGRATE_BK_FILE_END_PAGE_ID)
	{
	  return NO_ERROR;
	}
      if (id < 0)
	{
	  return ER_FAILED;
	}
      if (file != NULL)
	{
	  if ((size_t) id >= file->blocks.size ())
	    {
	      file->blocks.resize (id + 1, MIGRATE_BK_BLOCK { -1, 0 });
	    }
	  file->blocks[id] = blk;
	}
    }
}

/* read one backup volume's header and index its blocks */
static int
migrate_bk_open_one (const char *path, MIGRATE_BK_VOLUME *bk)
{
  bk->path = path;
  bk->fd = open (path, O_RDONLY);
  if (bk->fd < 0)
    {
      fprintf (stderr, "cannot open the backup volume %s: %s\n", path, strerror (errno));
      return ER_FAILED;
    }

  FILEIO_BACKUP_HEADER *hdr = &bk->hdr;
  struct stat st;
  if (fstat (bk->fd, &st) != 0 || !migrate_bk_pread (bk, 0, hdr, sizeof (*hdr)))
    {
      fprintf (stderr, "cannot read the backup header from %s\n", path);
      return ER_FAILED;
    }
  if (strncmp (hdr->magic, CUBRID_MAGIC_DATABASE_BACKUP, sizeof (CUBRID_MAGIC_DATABASE_BACKUP)) != 0)
    {
      fprintf (stderr, "%s is not a backup volume\n", path);
      return ER_FAILED;
    }
  if (hdr->bk_hdr_version != MIGRATE_BK_HEADER_VERSION)
    {
      fprintf (stderr, "%s: backup header version %d is not one this tool reads (%d)\n", path,
	       hdr->bk_hdr_version, MIGRATE_BK_HEADER_VERSION);
      return ER_FAILED;
    }
  if (hdr->level < FILEIO_BACKUP_FULL_LEVEL || hdr->level >= FILEIO_BACKUP_UNDEFINED_LEVEL)
    {
      fprintf (stderr, "%s: backup level %d is not one this tool knows\n", path, (int) hdr->level);
      return ER_FAILED;
    }
  if (hdr->zip_method != FILEIO_ZIP_NONE_METHOD && hdr->zip_method != FILEIO_ZIP_LZ4_METHOD)
    {
      fprintf (stderr, "%s: backup compression method %d is not supported\n", path, (int) hdr->zip_method);
      return ER_FAILED;
    }
  if (hdr->db_iopagesize <= 0 || hdr->bkpagesize <= 0 || hdr->bkpagesize % hdr->db_iopagesize != 0)
    {
      fprintf (stderr, "%s: backup page size %d does not hold whole %d byte pages\n", path, hdr->bkpagesize,
	       hdr->db_iopagesize);
      return ER_FAILED;
    }

  bk->block_size = hdr->bkpagesize;
  bk->node_size = hdr->bkpagesize + (int) (offsetof (FILEIO_BACKUP_PAGE, iopage) + sizeof (PAGEID));
  bk->compressed = hdr->zip_method != FILEIO_ZIP_NONE_METHOD;

  if (bk->node_size > hp_bk_node_max)
    {
      char *buf = (char *) realloc (hp_bk_zip_buf, bk->node_size);
      if (buf == NULL)
	{
	  return ER_FAILED;
	}
      hp_bk_zip_buf = buf;
      hp_bk_node_max = bk->node_size;
    }
  char *node = (char *) malloc (bk->node_size);
  if (node == NULL)
    {
      return ER_FAILED;
    }

  /*
   * Walk the files.  The data volumes and the active log are kept, the rest -- the keys, the
   * volume and log information files, archives -- stepped over.  The paths the backup names are
   * where the files were on the machine that took it, so they are not used.
   */
  off_t pos = MIGRATE_BK_HEADER_IO_SIZE;
  int error = NO_ERROR;
  for (;;)
    {
      PAGEID id;
      MIGRATE_BK_FILE_HEADER fh;

      if (!migrate_bk_pread (bk, pos, &id, sizeof (id)))
	{
	  fprintf (stderr, "%s ends before its end mark; a backup split over several volumes is not supported\n",
		   path);
	  error = ER_FAILED;
	  break;
	}
      if (id == MIGRATE_BK_END_PAGE_ID)
	{
	  break;
	}
      if (id != MIGRATE_BK_FILE_START_PAGE_ID
	  || !migrate_bk_pread (bk, pos + (off_t) offsetof (FILEIO_BACKUP_PAGE, iopage), &fh, sizeof (fh)))
	{
	  fprintf (stderr, "%s is damaged: no file header at offset %lld\n", path, (long long) pos);
	  error = ER_FAILED;
	  break;
	}
      pos += (off_t) (offsetof (FILEIO_BACKUP_PAGE, iopage) + sizeof (fh));

      MIGRATE_BK_FILE *file = NULL;
      if (fh.volid >= LOG_DBFIRST_VOLID || fh.volid == LOG_DBLOG_ACTIVE_VOLID)
	{
	  file = &bk->files[fh.volid];
	  file->nbytes = fh.nbytes;
	}
      if (migrate_bk_scan_file (bk, &pos, file, node) != NO_ERROR)
	{
	  /* a backup split into several volumes stops in the middle of a block, as a cut one does */
	  if (pos > st.st_size - (off_t) sizeof (int))
	    {
	      fprintf (stderr, "%s ends before its end mark; a backup split over several volumes is not"
		       " supported\n", path);
	    }
	  else
	    {
	      fprintf (stderr, "%s is damaged: a block of volume %d does not read back\n", path, (int) fh.volid);
	    }
	  error = ER_FAILED;
	  break;
	}
    }
  free (node);
  return error;
}

/*
 * Put the backups in level order and make sure they are one chain: the full backup, then each
 * level taken on top of the one below -- which it says by starting where the one below stopped.
 * An incremental backup taken again on top of a later one of the level below does not follow it,
 * and neither does one of another database.
 */
static int
migrate_bk_check_chain (void)
{
  std::sort (hp_bks.begin (), hp_bks.end (), [] (const MIGRATE_BK_VOLUME &a, const MIGRATE_BK_VOLUME &b)
  {
    return a.hdr.level < b.hdr.level;
  });

  for (size_t i = 0; i < hp_bks.size (); i++)
    {
      const MIGRATE_BK_VOLUME &bk = hp_bks[i];

      if ((size_t) bk.hdr.level != i)
	{
	  if (i == 0)
	    {
	      fprintf (stderr, "no full (level 0) backup given; %s is level %d, which holds only the pages changed"
		       " since the backup a level below it\n", bk.path.c_str (), (int) bk.hdr.level);
	    }
	  else
	    {
	      fprintf (stderr, "the backups have to be one of each level from 0 up; %s is level %d after level %d\n",
		       bk.path.c_str (), (int) bk.hdr.level, (int) hp_bks[i - 1].hdr.level);
	    }
	  return ER_FAILED;
	}
      if (i == 0)
	{
	  continue;
	}

      const MIGRATE_BK_VOLUME &below = hp_bks[i - 1];
      if (bk.hdr.db_creation != below.hdr.db_creation || bk.hdr.db_iopagesize != below.hdr.db_iopagesize)
	{
	  fprintf (stderr, "%s and %s are backups of different databases\n", bk.path.c_str (), below.path.c_str ());
	  return ER_FAILED;
	}
      if (!LSA_EQ (&bk.hdr.start_lsa, &below.hdr.chkpt_lsa))
	{
	  fprintf (stderr, "%s (level %d) was not taken on top of %s: it starts at %lld|%d, that one stops at"
		   " %lld|%d\n", bk.path.c_str (), (int) bk.hdr.level, below.path.c_str (),
		   (long long) bk.hdr.start_lsa.pageid, (int) bk.hdr.start_lsa.offset,
		   (long long) below.hdr.chkpt_lsa.pageid, (int) below.hdr.chkpt_lsa.offset);
	  return ER_FAILED;
	}
    }
  return NO_ERROR;
}

/* paths is one backup volume, or several separated by commas: the full backup and the levels on it */
static int
migrate_bk_open (const char *paths, MIGRATE_SRC_FORMAT *fmt)
{
  std::string list = paths;
  size_t start = 0;
  while (start <= list.size ())
    {
      size_t comma = list.find (',', start);
      std::string path = list.substr (start, comma == std::string::npos ? std::string::npos : comma - start);
      start = comma == std::string::npos ? list.size () + 1 : comma + 1;
      if (path.empty ())
	{
	  continue;
	}

      hp_bks.emplace_back ();
      hp_bks.back ().fd = -1;
      if (migrate_bk_open_one (path.c_str (), &hp_bks.back ()) != NO_ERROR)
	{
	  return ER_FAILED;
	}
    }
  if (hp_bks.empty () || migrate_bk_check_chain () != NO_ERROR)
    {
      return ER_FAILED;
    }

  /* the release is told the same way as for a database: by the active log's header, the latest one */
  const MIGRATE_BK_VOLUME &top = hp_bks.back ();
  auto lit = top.files.find (LOG_DBLOG_ACTIVE_VOLID);
  char *node = (char *) malloc (top.node_size);
  int error = NO_ERROR;
  if (node == NULL)
    {
      return ER_FAILED;
    }
  if (lit == top.files.end () || lit->second.blocks.empty () || lit->second.blocks[0].offset < 0
      || migrate_bk_load_block (&top, &lit->second.blocks[0], node) != NO_ERROR)
    {
      fprintf (stderr, "%s has no active log to tell the source release from\n", top.path.c_str ());
      error = ER_FAILED;
    }
  else
    {
      error = migrate_src_detect_log_header (node + offsetof (FILEIO_BACKUP_PAGE, iopage), fmt);
    }
  free (node);
  if (error != NO_ERROR)
    {
      return error;
    }
  if (fmt->io_page_size != top.hdr.db_iopagesize)
    {
      fprintf (stderr, "the backup header says %d byte pages, its log header %d\n", top.hdr.db_iopagesize,
	       fmt->io_page_size);
      return ER_FAILED;
    }

  for (int i = 0; i < MIGRATE_BK_CACHE_SLOTS; i++)
    {
      hp_bk_cache[i].level = -1;
      hp_bk_cache[i].volid = NULL_VOLID;
      hp_bk_cache[i].block = -1;
      hp_bk_cache[i].node = NULL;
    }
  hp_bk_cache_next = 0;

  migrate_heap_set_format (fmt);

  for (const MIGRATE_BK_VOLUME &bk : hp_bks)
    {
      int n_volumes = 0;
      for (auto &it : bk.files)
	{
	  n_volumes += it.first >= LOG_DBFIRST_VOLID ? 1 : 0;
	}
      printf ("source backup level %d: %s, %s, %d data volume(s)\n", (int) bk.hdr.level, bk.path.c_str (),
	      bk.compressed ? "LZ4" : "not compressed", n_volumes);
    }
  /*
   * Nothing replays the backup's log, so its pages are taken as they were copied.  A backup taken
   * while transactions ran is only made consistent by restoredb replaying that log.
   */
  printf ("  the pages are read as backed up, without replaying the log: take the backup stand-alone (-S)\n"
	  "  or while nothing writes to the database\n");
  return NO_ERROR;
}

/* where page volid|pageid is in one level, or NULL when that level does not have it */
static const MIGRATE_BK_BLOCK *
migrate_bk_find_block (const MIGRATE_BK_VOLUME *bk, int volid, PAGEID pageid, int *block, off_t *in_block)
{
  auto fit = bk->files.find (volid);
  if (fit == bk->files.end ())
    {
      return NULL;
    }

  const int per_block = bk->block_size / hp_io_page_size;
  *block = pageid / per_block;
  *in_block = offsetof (FILEIO_BACKUP_PAGE, iopage) + (off_t) (pageid % per_block) * hp_io_page_size;
  if ((size_t) *block >= fit->second.blocks.size () || fit->second.blocks[*block].offset < 0)
    {
      return NULL;
    }
  return &fit->second.blocks[*block];
}

static char *
migrate_bk_read_page (int volid, PAGEID pageid, char *iopage)
{
  /* the latest level that has the volume says how big it is; volumes do not shrink */
  const MIGRATE_BK_FILE *latest = NULL;
  for (size_t i = hp_bks.size (); i-- > 0 && latest == NULL;)
    {
      auto fit = hp_bks[i].files.find (volid);
      latest = fit == hp_bks[i].files.end () ? NULL : &fit->second;
    }
  if (latest == NULL)
    {
      fprintf (stderr, "no volume for volid %d in the backup\n", volid);
      return NULL;
    }
  if (pageid < 0 || (INT64) (pageid + 1) * hp_io_page_size > latest->nbytes)
    {
      fprintf (stderr, "page %d|%d is past the end of the backed up volume\n", volid, pageid);
      return NULL;
    }

  int level = -1, block = -1;
  off_t in_block = 0;
  const MIGRATE_BK_BLOCK *blk = NULL;
  for (level = (int) hp_bks.size () - 1; level >= 0; level--)
    {
      blk = migrate_bk_find_block (&hp_bks[level], volid, pageid, &block, &in_block);
      if (blk != NULL)
	{
	  break;
	}
    }
  if (blk == NULL)
    {
      fprintf (stderr, "the backup does not have page %d|%d\n", volid, pageid);
      return NULL;
    }

  const MIGRATE_BK_VOLUME *bk = &hp_bks[level];
  if (blk->length == bk->node_size)
    {
      if (!migrate_bk_pread (bk, blk->offset + in_block, iopage, hp_io_page_size))
	{
	  fprintf (stderr, "short read at %d|%d in %s (%s)\n", volid, pageid, bk->path.c_str (), strerror (errno));
	  return NULL;
	}
      return iopage;
    }

  /* a heap walk stays in one block for a while and then moves on; a few blocks cover the jumps */
  MIGRATE_BK_CACHE_SLOT *slot = NULL;
  for (int i = 0; i < MIGRATE_BK_CACHE_SLOTS; i++)
    {
      if (hp_bk_cache[i].level == level && hp_bk_cache[i].volid == volid && hp_bk_cache[i].block == block)
	{
	  slot = &hp_bk_cache[i];
	  break;
	}
    }
  if (slot == NULL)
    {
      slot = &hp_bk_cache[hp_bk_cache_next];
      hp_bk_cache_next = (hp_bk_cache_next + 1) % MIGRATE_BK_CACHE_SLOTS;
      if (slot->node == NULL)
	{
	  slot->node = (char *) malloc (hp_bk_node_max);
	  if (slot->node == NULL)
	    {
	      return NULL;
	    }
	}
      slot->level = -1;
      if (migrate_bk_load_block (bk, blk, slot->node) != NO_ERROR)
	{
	  fprintf (stderr, "cannot decompress the block holding page %d|%d in %s\n", volid, pageid,
		   bk->path.c_str ());
	  return NULL;
	}
      slot->level = level;
      slot->volid = volid;
      slot->block = block;
    }
  memcpy (iopage, slot->node + in_block, hp_io_page_size);
  return iopage;
}

static void
migrate_bk_close (void)
{
  for (int i = 0; i < MIGRATE_BK_CACHE_SLOTS; i++)
    {
      if (hp_bk_cache[i].node != NULL)
	{
	  free_and_init (hp_bk_cache[i].node);
	}
      hp_bk_cache[i].level = -1;
    }
  if (hp_bk_zip_buf != NULL)
    {
      free_and_init (hp_bk_zip_buf);
    }
  hp_bk_node_max = 0;
  for (MIGRATE_BK_VOLUME &bk : hp_bks)
    {
      if (bk.fd >= 0)
	{
	  close (bk.fd);
	}
    }
  hp_bks.clear ();
}

/* ------------------------------------------------------------------ source: either */

/*
 * A backup volume starts with its header, and the header's magic tells it from a database volume.
 * Several backups come separated by commas; the first one decides.
 */
static bool
migrate_src_is_backup (const char *src)
{
  std::string first = src;
  first = first.substr (0, first.find (','));

  struct stat st;
  if (stat (first.c_str (), &st) != 0 || !S_ISREG (st.st_mode))
    {
      return false;
    }

  int fd = open (first.c_str (), O_RDONLY);
  if (fd < 0)
    {
      return false;
    }
  char magic[CUBRID_MAGIC_MAX_LENGTH];
  ssize_t n = pread (fd, magic, sizeof (magic), offsetof (FILEIO_BACKUP_HEADER, magic));
  close (fd);
  return n == (ssize_t) sizeof (magic)
	 && strncmp (magic, CUBRID_MAGIC_DATABASE_BACKUP, sizeof (CUBRID_MAGIC_DATABASE_BACKUP)) == 0;
}

int
migrate_src_open (const char *src, MIGRATE_SRC_FORMAT *fmt)
{
  if (migrate_src_is_backup (src))
    {
      return migrate_bk_open (src, fmt);
    }
  return migrate_vol_open (src, fmt);
}

void
migrate_heap_close (void)
{
  for (auto &it : hp_fds)
    {
      close (it.second);
    }
  hp_fds.clear ();
  hp_volumes.clear ();
  migrate_bk_close ();
}

char *
migrate_heap_read_page (int volid, PAGEID pageid, char *iopage)
{
  char *page = !hp_bks.empty () ? migrate_bk_read_page (volid, pageid, iopage)
	       : migrate_vol_read_page (volid, pageid, iopage);

  return page == NULL ? NULL : page + hp_format.page_prefix_size;
}

/* guava's slot lookup, spelled out against the raw page image */
SPAGE_SLOT *
migrate_heap_page_slot (char *page, PGSLOTID slot_id)
{
  SPAGE_SLOT *slot_p = (SPAGE_SLOT *) (page + hp_db_page_size - sizeof (SPAGE_SLOT));
  return slot_p - slot_id;
}

static int
migrate_heap_scan_page (char *page, int volid, PAGEID pageid, MIGRATE_HEAP_RECORD_FN fn, void *arg,
			MIGRATE_HEAP_STATS  *stats)
{
  SPAGE_HEADER *ph = (SPAGE_HEADER *) page;

  for (PGSLOTID s = MIGRATE_HEAP_HEADER_AND_CHAIN_SLOTID + 1; s < ph->num_slots; s++)
    {
      SPAGE_SLOT *slot = migrate_heap_page_slot (page, s);
      switch (slot->record_type)
	{
	case REC_HOME:
	  stats->rec_home++;
	  break;
	case REC_BIGONE:
	  stats->rec_bigone++;
	  break;
	case REC_RELOCATION:
	  stats->rec_relocation++;
	  break;
	case REC_NEWHOME:
	  /* the body of a relocated row; its REC_RELOCATION slot is the row */
	  stats->rec_newhome++;
	  continue;
	case REC_MARKDELETED:
	case REC_DELETED_WILL_REUSE:
	case REC_UNKNOWN:
	  continue;
	default:
	  stats->rec_other++;
	  continue;
	}

      OID src_oid;
      src_oid.volid = (INT16) volid;
      src_oid.pageid = pageid;
      src_oid.slotid = s;

      int error = fn (page + slot->offset_to_record, (int) slot->record_length, slot->record_type, &src_oid, arg);
      if (error != NO_ERROR)
	{
	  return error;
	}
    }
  return NO_ERROR;
}

int
migrate_heap_walk (int hfid_volid, PAGEID hpgid, MIGRATE_HEAP_RECORD_FN fn, void *arg, MIGRATE_HEAP_STATS *stats)
{
  char *iopage = (char *) malloc (hp_io_page_size);
  if (iopage == NULL)
    {
      return ER_FAILED;
    }

  memset (stats, 0, sizeof (*stats));

  /* the header page holds HEAP_HDR_STATS in slot 0 and rows in the rest */
  char *page = migrate_heap_read_page (hfid_volid, hpgid, iopage);
  if (page == NULL)
    {
      free (iopage);
      return ER_FAILED;
    }

  SPAGE_SLOT *hslot = migrate_heap_page_slot (page, MIGRATE_HEAP_HEADER_AND_CHAIN_SLOTID);
  VPID next;
  memcpy (&next, page + hslot->offset_to_record + hp_format.hdr_next_vpid_offset, sizeof (VPID));

  int error = migrate_heap_scan_page (page, hfid_volid, hpgid, fn, arg, stats);
  stats->pages++;

  VPID cur = next;
  while (error == NO_ERROR && cur.pageid != NULL_PAGEID)
    {
      page = migrate_heap_read_page (cur.volid, cur.pageid, iopage);
      if (page == NULL)
	{
	  error = ER_FAILED;
	  break;
	}
      stats->pages++;

      error = migrate_heap_scan_page (page, cur.volid, cur.pageid, fn, arg, stats);
      if (error != NO_ERROR)
	{
	  break;
	}

      SPAGE_SLOT *cslot = migrate_heap_page_slot (page, MIGRATE_HEAP_HEADER_AND_CHAIN_SLOTID);
      MIGRATE_HEAP_CHAIN chain;
      memcpy (&chain, page + cslot->offset_to_record, sizeof (chain));
      cur = chain.next_vpid;
    }

  free (iopage);
  return error;
}

/*
 * STR_SIZE is file-local to object_primitive.c; the fixed width of a CHAR in the source is the
 * same expression there, so it is repeated rather than reached for.
 */
#define MIGRATE_STR_SIZE(prec, codeset) \
  (((codeset) == INTL_CODESET_RAW_BITS) ? (((prec) + 7) / 8) : INTL_CODESET_MULT (codeset) * (prec))

static bool
migrate_src_type_moved (const MIGRATE_SRC_FORMAT *fmt, DB_TYPE type)
{
  for (int i = 0; i < fmt->n_moved_to_variable; i++)
    {
      if (fmt->moved_to_variable[i] == type)
	{
	  return true;
	}
    }
  return false;
}

/* was this attribute stored in the fixed block by the source? */
static bool
migrate_src_is_fixed (const MIGRATE_SRC_FORMAT *fmt, TP_DOMAIN *domain)
{
  if (migrate_src_type_moved (fmt, TP_DOMAIN_TYPE (domain)))
    {
      return true;
    }
  return domain->type->variable_p == 0;
}

/*
 * Width of a fixed attribute in the source's encoding.  It is tp_domain_disk_size () except for
 * the types that moved: this release sizes them the variable way, and NUMERIC also changed the
 * constant it uses.
 */
static int
migrate_src_fixed_disk_size (const MIGRATE_SRC_FORMAT *fmt, TP_DOMAIN *domain)
{
  switch (TP_DOMAIN_TYPE (domain))
    {
    case DB_TYPE_NUMERIC:
      return fmt->numeric_disk_size;

    case DB_TYPE_CHAR:
    case DB_TYPE_NCHAR_DEPRECATED:
      if (domain->precision == TP_FLOATING_PRECISION_VALUE)
	{
	  return -1;
	}
      return MIGRATE_STR_SIZE (domain->precision, TP_DOMAIN_CODESET (domain));

    default:
      return tp_domain_disk_size (domain);
    }
}

void
migrate_src_layout_free (MIGRATE_SRC_LAYOUT *layout)
{
  free (layout->attrs);
  layout->attrs = NULL;
  layout->n_attrs = layout->n_fixed = layout->n_variable = layout->fixed_length = 0;
}

int
migrate_src_layout_build (const MIGRATE_SRC_FORMAT *fmt, HEAP_CACHE_ATTRINFO *attr_info,
			  MIGRATE_SRC_LAYOUT *layout)
{
  int n = attr_info->num_values;
  int n_fixed = 0, n_var = 0;
  int offset = 0;
  MIGRATE_SRC_ATTR *fixed, *variable;

  memset (layout, 0, sizeof (*layout));
  if (n <= 0)
    {
      return ER_FAILED;
    }

  layout->attrs = (MIGRATE_SRC_ATTR *) calloc (n, sizeof (MIGRATE_SRC_ATTR));
  fixed = (MIGRATE_SRC_ATTR *) calloc (n, sizeof (MIGRATE_SRC_ATTR));
  variable = (MIGRATE_SRC_ATTR *) calloc (n, sizeof (MIGRATE_SRC_ATTR));
  if (layout->attrs == NULL || fixed == NULL || variable == NULL)
    {
      free (fixed);
      free (variable);
      migrate_src_layout_free (layout);
      return ER_FAILED;
    }
  layout->n_attrs = n;

  /*
   * The target's attributes come in its own storage order, fixed first.  Splitting them by the
   * source's rule keeps the relative order inside each group, and that is the order the source
   * had as well: both releases append to the variable list in the same sequence.
   */
  for (int i = 0; i < n; i++)
    {
      OR_ATTRIBUTE *att = attr_info->values[i].last_attrepr;
      MIGRATE_SRC_ATTR a;

      a.id = att->id;
      a.def_order = att->def_order;
      a.value_index = i;
      a.domain = att->domain;
      a.is_fixed = migrate_src_is_fixed (fmt, att->domain);
      a.location = 0;
      a.disk_size = 0;

      if (a.is_fixed)
	{
	  a.disk_size = migrate_src_fixed_disk_size (fmt, att->domain);
	  if (a.disk_size < 0)
	    {
	      /* a floating-precision CHAR was never fixed; nothing here can place it */
	      free (fixed);
	      free (variable);
	      migrate_src_layout_free (layout);
	      return ER_FAILED;
	    }
	  fixed[n_fixed++] = a;
	}
      else
	{
	  variable[n_var++] = a;
	}
    }

  /*
   * The source ordered its fixed block by descending alignment, ties broken by smaller disk
   * size -- order_atts_by_alignment () in schema_manager.c.
   *
   * It takes the first of equals, so what settles a full tie is the order the attributes sat in
   * its own list, and that order cannot be recovered here: it depends on how the class was built.
   * A class defined in one CREATE TABLE ends up with the reverse of its column order, while one
   * grown by ALTER ADD ends up in the order the columns were added, and the target -- always
   * rebuilt as CREATE plus one ALTER ADD -- matches neither reliably. Two fixed attributes with
   * the same alignment and the same width are therefore left as ambiguous rather than guessed at.
   */
  for (int i = 1; i < n_fixed; i++)
    {
      MIGRATE_SRC_ATTR key = fixed[i];
      int key_align = key.domain->type->alignment;
      int j = i - 1;

      while (j >= 0)
	{
	  int j_align = fixed[j].domain->type->alignment;

	  if (! (key_align > j_align || (key_align == j_align && key.disk_size < fixed[j].disk_size)))
	    {
	      break;
	    }
	  fixed[j + 1] = fixed[j];
	  j--;
	}
      fixed[j + 1] = key;
    }

  for (int i = 0; i < n_fixed; i++)
    {
      fixed[i].location = offset;
      offset += fixed[i].disk_size;
      layout->attrs[i] = fixed[i];
    }
  for (int i = 0; i < n_var; i++)
    {
      variable[i].location = i;
      layout->attrs[n_fixed + i] = variable[i];
    }

  free (fixed);
  free (variable);

  /* a full tie leaves the source's order unknowable; say so rather than pick one */
  layout->order_ambiguous = false;
  for (int i = 1; i < n_fixed; i++)
    {
      if (layout->attrs[i].domain->type->alignment == layout->attrs[i - 1].domain->type->alignment
	  && layout->attrs[i].disk_size == layout->attrs[i - 1].disk_size)
	{
	  layout->order_ambiguous = true;
	  break;
	}
    }

  layout->n_fixed = n_fixed;
  layout->n_variable = n_var;
  layout->fixed_length = DB_ATT_ALIGN (offset);
  return NO_ERROR;
}

/* read one value in the source's encoding; only the types that moved differ from this release */
static int
migrate_src_readval (const MIGRATE_SRC_FORMAT *fmt, char *ptr, int size, TP_DOMAIN *domain, DB_VALUE *value)
{
  switch (TP_DOMAIN_TYPE (domain))
    {
    case DB_TYPE_NUMERIC:
    {
      /*
       * The source holds the unscaled value as a big-endian two's complement integer, sign and
       * all, in fmt->numeric_disk_size bytes with nothing in front of it.  This release keeps the
       * magnitude right-aligned in a DB_NUMERIC_BUF_SIZE buffer and carries the sign beside it,
       * so a negative value has to be negated on the way across.
       */
      unsigned char mag[DB_NUMERIC_BUF_SIZE];
      int n = fmt->numeric_disk_size;
      bool is_negative;

      if (n <= 0 || n > DB_NUMERIC_BUF_SIZE)
	{
	  return ER_FAILED;
	}

      is_negative = (((unsigned char *) ptr)[0] & 0x80) != 0;

      memset (mag, 0, sizeof (mag));
      memcpy (mag + (DB_NUMERIC_BUF_SIZE - n), ptr, n);

      if (is_negative)
	{
	  int carry = 1;

	  for (int i = DB_NUMERIC_BUF_SIZE - 1; i >= 0; i--)
	    {
	      int b = (unsigned char) (~mag[i]) + carry;
	      mag[i] = (unsigned char) (b & 0xFF);
	      carry = b >> 8;
	    }
	  /* the sign extension inverted to 0xFF..., which the add above carried away */
	  for (int i = 0; i < DB_NUMERIC_BUF_SIZE - n; i++)
	    {
	      mag[i] = 0;
	    }
	}

      db_make_numeric (value, (DB_C_NUMERIC) mag, domain->precision, domain->scale, DB_NUMERIC_BUF_SIZE,
		       is_negative, false);
      value->need_clear = false;
      return NO_ERROR;
    }

    case DB_TYPE_CHAR:
    case DB_TYPE_NCHAR_DEPRECATED:
    {
      /* the whole precision sits on disk, blank padded; the value keeps the characters it holds */
      int str_length = 0;

      intl_char_size ((unsigned char *) ptr, domain->precision, TP_DOMAIN_CODESET (domain), &str_length);
      if (str_length == 0)
	{
	  str_length = size;
	}
      db_make_char (value, domain->precision, ptr, str_length, TP_DOMAIN_CODESET (domain),
		    TP_DOMAIN_COLLATION (domain));
      value->need_clear = false;
      return NO_ERROR;
    }

    default:
    {
      OR_BUF buf;

      or_init (&buf, ptr, size);
      return domain->type->data_readval (&buf, value, domain, size, false, NULL, 0);
    }
    }
}

int
migrate_heap_follow_relocation (char *reloc_rec, int reloc_len, char *scratch_iopage, char **out_rec, int *out_len)
{
  OID forward_oid;
  char *page;
  SPAGE_SLOT *slot;

  if (reloc_len < OR_OID_SIZE)
    {
      return ER_FAILED;
    }
  COPY_OID (&forward_oid, (OID *) reloc_rec);

  page = migrate_heap_read_page (forward_oid.volid, forward_oid.pageid, scratch_iopage);
  if (page == NULL)
    {
      return ER_FAILED;
    }

  slot = migrate_heap_page_slot (page, forward_oid.slotid);
  if (slot->record_type != REC_NEWHOME)
    {
      return ER_FAILED;
    }

  *out_rec = page + slot->offset_to_record;
  *out_len = (int) slot->record_length;
  return NO_ERROR;
}

/*
 * The two overflow page shapes. Both are identical in the releases checked so far, so they are
 * spelled out here rather than kept in MIGRATE_SRC_FORMAT; if one ever differs, that is where
 * the difference belongs.
 *
 *   first page   VPID next_vpid; int length;  char data[]   -- length is the whole row
 *   later pages  VPID next_vpid;              char data[]
 */
#define MIGRATE_OVF_FIRST_DATA_OFFSET ((int) (sizeof (VPID) + sizeof (int)))
#define MIGRATE_OVF_REST_DATA_OFFSET  ((int) sizeof (VPID))

int
migrate_heap_read_overflow (char *bigone_rec, int reclen, char *scratch_iopage,
			    char **buf, int *buf_size, char **out_rec, int *out_len)
{
  OID ovf_oid;
  VPID next;
  char *page;
  int total, got = 0;
  int db_page_size = migrate_heap_db_page_size ();

  if (reclen < OR_OID_SIZE)
    {
      return ER_FAILED;
    }
  COPY_OID (&ovf_oid, (OID *) bigone_rec);

  next.volid = ovf_oid.volid;
  next.pageid = ovf_oid.pageid;

  page = migrate_heap_read_page (next.volid, next.pageid, scratch_iopage);
  if (page == NULL)
    {
      return ER_FAILED;
    }
  memcpy (&total, page + sizeof (VPID), sizeof (total));
  if (total <= 0)
    {
      return ER_FAILED;
    }

  if (*buf_size < total)
    {
      char *grown = (char *) realloc (*buf, total);

      if (grown == NULL)
	{
	  return ER_FAILED;
	}
      *buf = grown;
      *buf_size = total;
    }

  int offset = MIGRATE_OVF_FIRST_DATA_OFFSET;
  for (;;)
    {
      int on_page = db_page_size - offset;
      int take = (total - got < on_page) ? (total - got) : on_page;

      if (take > 0)
	{
	  memcpy (*buf + got, page + offset, take);
	  got += take;
	}
      if (got >= total)
	{
	  break;
	}

      memcpy (&next, page + 0, sizeof (VPID));
      if (next.pageid == NULL_PAGEID)
	{
	  /* the chain ended before the length promised by the first page */
	  return ER_FAILED;
	}
      page = migrate_heap_read_page (next.volid, next.pageid, scratch_iopage);
      if (page == NULL)
	{
	  return ER_FAILED;
	}
      offset = MIGRATE_OVF_REST_DATA_OFFSET;
    }

  *out_rec = *buf;
  *out_len = total;
  return NO_ERROR;
}

/*
 * Reading the classes of the source database out of its volumes.
 *
 * The engine bootstraps without a catalog, and this walks the same way it does: the volume
 * header names a heap kept for booting, its first record names the heap the class objects
 * live in, and each record there is one class, carrying its name and its HFID.  Where those
 * values sit is per release, so they come from MIGRATE_SRC_FORMAT rather than from this
 * release's structures -- see the checklist above migrate_Known_formats[].
 */

typedef struct migrate_class_map_ctx MIGRATE_CLASS_MAP_CTX;
struct migrate_class_map_ctx
{
  const MIGRATE_SRC_FORMAT *fmt;
  std::vector<MIGRATE_CLASS_ENTRY> *out;
  char *scratch;		/* an IO page of its own: the walk is using the caller's */
  char **ovf_buf;
  int *ovf_size;
  HFID rootclass_hfid;		/* filled by the first callback, used by the second */
  bool have_rootclass;
  int unreadable;
};

/*
 * Resolve a slot to the bytes of the row it stands for: a row that moved lives elsewhere, and
 * one too big for a page is in the overflow file.  Both already have their own readers.
 */
static int
migrate_class_map_row (MIGRATE_CLASS_MAP_CTX *ctx, int rec_type, char **rec, int *reclen)
{
  if (rec_type == REC_RELOCATION)
    {
      return migrate_heap_follow_relocation (*rec, *reclen, ctx->scratch, rec, reclen);
    }
  if (rec_type == REC_BIGONE)
    {
      return migrate_heap_read_overflow (*rec, *reclen, ctx->scratch, ctx->ovf_buf, ctx->ovf_size, rec, reclen);
    }
  return NO_ERROR;
}

static int
migrate_class_map_dbparm (char *rec, int reclen, int rec_type, const OID *src_oid, void *arg)
{
  MIGRATE_CLASS_MAP_CTX *ctx = (MIGRATE_CLASS_MAP_CTX *) arg;
  int need = ctx->fmt->dbparm_rootclass_hfid_offset + (int) sizeof (HFID);

  if (ctx->have_rootclass)
    {
      return NO_ERROR;		/* the boot parameters are the first record; the rest is not ours */
    }
  if (migrate_class_map_row (ctx, rec_type, &rec, &reclen) != NO_ERROR)
    {
      return ER_FAILED;
    }
  if (reclen < need)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
      return ER_FAILED;
    }

  /* written as a structure image, so it is copied out rather than decoded */
  memcpy (&ctx->rootclass_hfid, rec + ctx->fmt->dbparm_rootclass_hfid_offset, sizeof (HFID));
  ctx->have_rootclass = true;
  return NO_ERROR;
}

static int
migrate_class_map_class (char *rec, int reclen, int rec_type, const OID *src_oid, void *arg)
{
  MIGRATE_CLASS_MAP_CTX *ctx = (MIGRATE_CLASS_MAP_CTX *) arg;
  const MIGRATE_SRC_FORMAT *fmt = ctx->fmt;

  if (migrate_class_map_row (ctx, rec_type, &rec, &reclen) != NO_ERROR)
    {
      ctx->unreadable++;
      return NO_ERROR;
    }

  int hdr = OR_HEADER_SIZE (rec);
  int offset_size = OR_GET_OFFSET_SIZE (rec);
  char *var_table = rec + hdr;
  int name_off = OR_VAR_TABLE_ELEMENT_OFFSET_INTERNAL (var_table, fmt->class_name_index, offset_size);
  int name_len = OR_VAR_TABLE_ELEMENT_LENGTH_INTERNAL (var_table, fmt->class_name_index, offset_size);

  if (name_off <= 0 || name_len <= 0 || hdr + name_off + name_len > reclen)
    {
      ctx->unreadable++;
      return NO_ERROR;
    }

  OR_BUF buf;
  DB_VALUE value;
  or_init (&buf, rec + hdr + name_off, name_len);
  if (tp_String.data_readval (&buf, &value, NULL, name_len, false, NULL, 0) != NO_ERROR)
    {
      ctx->unreadable++;
      return NO_ERROR;
    }

  const char *name = db_get_string (&value);
  if (name == NULL || *name == '\0')
    {
      pr_clear_value (&value);
      ctx->unreadable++;
      return NO_ERROR;
    }

  MIGRATE_CLASS_ENTRY entry;
  memset (&entry, 0, sizeof (entry));
  strncpy (entry.name, name, sizeof (entry.name) - 1);
  pr_clear_value (&value);

  char *fixed = rec + OR_FIXED_ATTRIBUTES_OFFSET_INTERNAL (rec, fmt->class_var_att_count, offset_size);
  entry.hfid.vfid.fileid = OR_GET_INT (fixed + fmt->class_hfid_fileid_offset);
  entry.hfid.vfid.volid = (VOLID) OR_GET_INT (fixed + fmt->class_hfid_volid_offset);
  entry.hfid.hpgid = OR_GET_INT (fixed + fmt->class_hfid_pageid_offset);
  entry.is_system = (OR_GET_INT (fixed + fmt->class_flags_offset) & fmt->class_flag_system) != 0;

  ctx->out->push_back (entry);
  return NO_ERROR;
}

int
migrate_src_class_map (const MIGRATE_SRC_FORMAT *fmt, MIGRATE_CLASS_ENTRY **entries, int *count)
{
  std::vector<MIGRATE_CLASS_ENTRY> found;
  MIGRATE_CLASS_MAP_CTX ctx;
  MIGRATE_HEAP_STATS stats;
  char *scratch = NULL;
  char *ovf_buf = NULL;
  int ovf_size = 0;
  int error = NO_ERROR;
  HFID boot_hfid;
  char *page;

  *entries = NULL;
  *count = 0;

  scratch = (char *) malloc (hp_io_page_size);
  if (scratch == NULL)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, (size_t) hp_io_page_size);
      return ER_FAILED;
    }

  ctx.fmt = fmt;
  ctx.out = &found;
  ctx.scratch = scratch;
  ctx.ovf_buf = &ovf_buf;
  ctx.ovf_size = &ovf_size;
  HFID_SET_NULL (&ctx.rootclass_hfid);
  ctx.have_rootclass = false;
  ctx.unreadable = 0;

  /* the boot heap, named by the first volume's header */
  page = migrate_heap_read_page (0, DISK_VOLHEADER_PAGE, scratch);
  if (page == NULL)
    {
      error = ER_FAILED;
      goto end;
    }
  memcpy (&boot_hfid, page + fmt->volheader_boot_hfid_offset, sizeof (HFID));
  if (HFID_IS_NULL (&boot_hfid))
    {
      error = ER_FAILED;
      goto end;
    }

  error = migrate_heap_walk (boot_hfid.vfid.volid, boot_hfid.hpgid, migrate_class_map_dbparm, &ctx, &stats);
  if (error != NO_ERROR || !ctx.have_rootclass || HFID_IS_NULL (&ctx.rootclass_hfid))
    {
      error = ER_FAILED;
      goto end;
    }

  error = migrate_heap_walk (ctx.rootclass_hfid.vfid.volid, ctx.rootclass_hfid.hpgid, migrate_class_map_class,
			     &ctx, &stats);
  if (error != NO_ERROR)
    {
      goto end;
    }
  if (ctx.unreadable > 0)
    {
      /* a class this cannot read is a class the caller cannot ask for by name */
      fprintf (stderr, "warning: %d class record(s) of the source could not be read\n", ctx.unreadable);
    }

  *entries = (MIGRATE_CLASS_ENTRY *) malloc (sizeof (MIGRATE_CLASS_ENTRY) * (found.size () + 1));
  if (*entries == NULL)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1,
	      sizeof (MIGRATE_CLASS_ENTRY) * (found.size () + 1));
      error = ER_FAILED;
      goto end;
    }
  memcpy (*entries, found.data (), sizeof (MIGRATE_CLASS_ENTRY) * found.size ());
  *count = (int) found.size ();

end:
  free (scratch);
  free (ovf_buf);
  return error;
}

void
migrate_src_class_map_free (MIGRATE_CLASS_ENTRY *entries)
{
  free (entries);
}

const MIGRATE_CLASS_ENTRY *
migrate_src_class_find (const MIGRATE_CLASS_ENTRY *entries, int count, const char *name)
{
  for (int i = 0; i < count; i++)
    {
      if (strcmp (entries[i].name, name) == 0)
	{
	  return &entries[i];
	}
    }
  return NULL;
}

/*
 * Does this record actually have the shape the layout describes?
 *
 * A record carries the representation it was written under, but representation ids are not
 * comparable across databases -- replaying the schema can number them differently, and it does
 * for inherited classes. What is comparable is the shape itself: the first variable value sits
 * exactly after the variable table, the fixed block and the bound bits, so that offset pins down
 * both the number of variable attributes and the width of the fixed block. A record written under
 * some other representation fails this, which is what stops it from being decoded into
 * plausible-looking nonsense.
 */
int
migrate_src_layout_matches (const MIGRATE_SRC_LAYOUT *layout, char *rec, int reclen)
{
  int hdr = OR_HEADER_SIZE (rec);
  int offset_size = OR_GET_OFFSET_SIZE (rec);
  int var_table_size = OR_VAR_TABLE_SIZE_INTERNAL (layout->n_variable, offset_size);
  int bound_bytes = 0;
  int expected;

  if (OR_GET_BOUND_BIT_FLAG (rec))
    {
      bound_bytes = OR_BOUND_BIT_BYTES (layout->n_fixed);
    }
  expected = var_table_size + layout->fixed_length + bound_bytes;

  if (layout->n_variable > 0)
    {
      char *var_table = rec + hdr;
      int first = OR_VAR_TABLE_ELEMENT_OFFSET_INTERNAL (var_table, 0, offset_size);

      return (first == expected) ? NO_ERROR : ER_FAILED;
    }

  /* with no variable attributes the record is just the header, the fixed block and the bits */
  return (hdr + expected <= reclen) ? NO_ERROR : ER_FAILED;
}

int
migrate_src_read_record (const MIGRATE_SRC_FORMAT *fmt, const MIGRATE_SRC_LAYOUT *layout,
			 char *rec, int reclen, HEAP_CACHE_ATTRINFO *attr_info)
{
  int hdr = OR_HEADER_SIZE (rec);
  int offset_size = OR_GET_OFFSET_SIZE (rec);
  char *var_table = rec + hdr;
  int fixed_start = hdr + OR_VAR_TABLE_SIZE_INTERNAL (layout->n_variable, offset_size);
  char *bound_bits = NULL;

  if (OR_GET_BOUND_BIT_FLAG (rec))
    {
      bound_bits = rec + fixed_start + layout->fixed_length;
    }

  for (int i = 0; i < layout->n_attrs; i++)
    {
      const MIGRATE_SRC_ATTR *a = &layout->attrs[i];
      DB_VALUE *value = &attr_info->values[a->value_index].dbvalue;

      pr_clear_value (value);
      db_make_null (value);
      attr_info->values[a->value_index].state = HEAP_READ_ATTRVALUE;

      if (a->is_fixed)
	{
	  /* i is the storage order, and the bound bits are indexed the same way */
	  if (bound_bits != NULL && !OR_GET_BOUND_BIT (bound_bits, i))
	    {
	      continue;
	    }
	  if (fixed_start + a->location + a->disk_size > reclen)
	    {
	      return ER_FAILED;
	    }
	  if (migrate_src_readval (fmt, rec + fixed_start + a->location, a->disk_size, a->domain, value) != NO_ERROR)
	    {
	      return ER_FAILED;
	    }
	}
      else
	{
	  int off = hdr + OR_VAR_TABLE_ELEMENT_OFFSET_INTERNAL (var_table, a->location, offset_size);
	  int len = OR_VAR_TABLE_ELEMENT_LENGTH_INTERNAL (var_table, a->location, offset_size);

	  if (len == 0)
	    {
	      continue;		/* an empty slot in the variable table is a NULL */
	    }
	  if (off < 0 || len < 0 || off + len > reclen)
	    {
	      return ER_FAILED;
	    }
	  if (migrate_src_readval (fmt, rec + off, len, a->domain, value) != NO_ERROR)
	    {
	      return ER_FAILED;
	    }
	}
    }

  return NO_ERROR;
}
