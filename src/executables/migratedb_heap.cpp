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

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <map>
#include <string>

#include <fcntl.h>
#include <unistd.h>

#include "error_code.h"

#include <cmath>
#include <climits>

// XXX: SHOULD BE THE LAST INCLUDE HEADER
#include "memory_wrapper.hpp"

/*
 * Known source releases.  A row is only here once its on-disk shapes have been checked against
 * that release's headers; an unverified release is refused rather than guessed at.
 */
static const DB_TYPE mv_11_4[] = { DB_TYPE_CHAR, DB_TYPE_NCHAR_DEPRECATED, DB_TYPE_NUMERIC };

static const MIGRATE_SRC_FORMAT migrate_Known_formats[] =
{
  /* release  compat  io  log  prefix  reserved  next_vpid  moved_to_variable        n */
  {"11.4", 11.4f, 0, 0, 32, 40, 16, mv_11_4, (int) (sizeof (mv_11_4) / sizeof (mv_11_4[0]))},
};

static const int migrate_Known_format_count =
	(int) (sizeof (migrate_Known_formats) / sizeof (migrate_Known_formats[0]));

static MIGRATE_SRC_FORMAT hp_format;
static int hp_io_page_size = 0;
static int hp_db_page_size = 0;

/* volid -> volume file path, read from the database's _vinf file */
static std::map<int, std::string> hp_volumes;
static std::map<int, int> hp_fds;

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

int
migrate_src_detect (const char *db_path_prefix, MIGRATE_SRC_FORMAT *fmt)
{
  char path[PATH_MAX];
  snprintf (path, sizeof (path), "%s_lgat", db_path_prefix);

  int fd = open (path, O_RDONLY);
  if (fd < 0)
    {
      fprintf (stderr, "cannot open the source active log %s: %s\n", path, strerror (errno));
      return ER_FAILED;
    }

  char head[128];
  ssize_t n = pread (fd, head, sizeof (head), 0);
  close (fd);
  if (n != (ssize_t) sizeof (head))
    {
      fprintf (stderr, "cannot read the source log header from %s\n", path);
      return ER_FAILED;
    }

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

int
migrate_heap_open (const char *vinf_path, const MIGRATE_SRC_FORMAT *fmt)
{
  FILE *fp = fopen (vinf_path, "r");
  if (fp == NULL)
    {
      fprintf (stderr, "cannot open %s: %s\n", vinf_path, strerror (errno));
      return ER_FAILED;
    }

  hp_format = *fmt;
  hp_io_page_size = fmt->io_page_size;
  hp_db_page_size = fmt->io_page_size - fmt->page_reserved_size;

  char line[2048];
  while (fgets (line, sizeof (line), fp) != NULL)
    {
      int volid;
      char path[1024];
      if (sscanf (line, "%d %1023s", &volid, path) == 2 && volid >= 0)
	{
	  hp_volumes[volid] = path;
	}
    }
  fclose (fp);
  return NO_ERROR;
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
}

static int
migrate_heap_volume_fd (int volid)
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

char *
migrate_heap_read_page (int volid, PAGEID pageid, char *iopage)
{
  int fd = migrate_heap_volume_fd (volid);
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
  return iopage + hp_format.page_prefix_size;
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
