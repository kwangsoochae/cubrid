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
#include "object_representation.h"
#include "object_primitive.h"
#include "intl_support.h"
#include "dbtype.h"
#include "memory_alloc.h"

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
  /* release compat io log prefix reserved next_vpid moved_to_variable n numeric_disk_size
   *
   * 11.4's fixed NUMERIC is DB_NUMERIC_BUF_SIZE, which was 2 * sizeof (double) there and is 17 here.
   */
  {"11.4", 11.4f, 0, 0, 32, 40, 16, mv_11_4, (int) (sizeof (mv_11_4) / sizeof (mv_11_4[0])), 16},
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
