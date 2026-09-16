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
 * XASL (eXtented Access Specification Language) interpreter internal
 * definitions.
 * For a brief description of ASL principles see "Access Path Selection in a
 * Relational Database Management System" by P. Griffiths Selinger et al
 */

#ifndef _QUERY_EXECUTOR_H_
#define _QUERY_EXECUTOR_H_

#ident "$Id$"

#if !defined (SERVER_MODE) && !defined (SA_MODE)
#error Belongs to server module
#endif /* !defined (SERVER_MODE) && !defined (SA_MODE) */

#include "dbtype_def.h"
#include "query_list.h"
#include "system.h"
#include "thread_compat.hpp"

#include <time.h>

// forward definitions
struct func_pred;
struct pred_expr_with_context;
struct qfile_list_id;
struct qfile_tuple_record;
class regu_variable_node;
struct tp_domain;
struct valptr_list_node;
struct xasl_node;
struct xasl_state;
using XASL_STATE = xasl_state;

#define QEXEC_NULL_COMMAND_ID   -1	/* Invalid command identifier */

typedef enum
{
  TOPN_SUCCESS,
  TOPN_OVERFLOW,
  TOPN_FAILURE
} TOPN_STATUS;

struct topn_tuples;
typedef struct topn_tuples TOPN_TUPLES;

typedef struct upddel_class_instances_lock_info UPDDEL_CLASS_INSTANCE_LOCK_INFO;
struct upddel_class_instances_lock_info
{
  OID class_oid;
  bool instances_locked;
};

typedef struct val_descr VAL_DESCR;
struct val_descr
{
  DB_VALUE *dbval_ptr;		/* Array of values */
  int dbval_cnt;		/* Value Count */
  DB_DATETIME sys_datetime;
  DB_TIMESTAMP sys_epochtime;
  long lrand;
  double drand;
  XASL_STATE *xasl_state;	/* XASL_STATE pointer */
};				/* Value Descriptor */

/* Non-local control flow out of a PL/CSQL statement. RETURN, EXIT and CONTINUE are not
 * errors, so GOTO_EXIT_ON_ERROR cannot carry them: a statement returns NO_ERROR and raises
 * a signal instead, which the enclosing block or loop reads. */
typedef enum
{
  PLCSQL_SIGNAL_NONE = 0,
  PLCSQL_SIGNAL_RETURN,
  PLCSQL_SIGNAL_EXIT,
  PLCSQL_SIGNAL_CONTINUE
} PLCSQL_SIGNAL;

/* One activation of a PL/CSQL procedure. Locals live in slots the compiler numbers. */
typedef struct plcsql_cursor PLCSQL_CURSOR;
struct plcsql_cursor
{
  xasl_node *query;		/* the plan the declaration carries, recorded when the block runs */
  bool is_open;			/* between OPEN and CLOSE, which is when the list file is alive */
  bool scanning;		/* whether scan_id below has been opened on that list file */
  QFILE_LIST_SCAN_ID scan_id;	/* where the next FETCH reads. It outlives the statement that
				 * opened it, which is the whole difference from a SELECT ... INTO */
  int base_slot;		/* the first slot the cursor owns; see PLCSQL_CURSOR_ATTR_* */
  int cols_cnt;			/* how many columns its query gives back */
};

typedef struct plcsql_frame PLCSQL_FRAME;
struct plcsql_frame
{
  DB_VALUE *locals;
  int locals_cnt;

  PLCSQL_CURSOR *cursors;
  int cursors_cnt;

  PLCSQL_SIGNAL signal;
  int signal_level;		/* how many enclosing loops a labelled EXIT or CONTINUE leaves */

  DB_VALUE retval;		/* what a RETURN left for the caller to read; NULL until one runs,
				 * which is also what a function that falls off its end gives back */

  int exc;			/* the exception a handler is running on, -1 outside one. A bare RAISE
				 * reads it: what it re-raises is what the handler caught */
  char *caught;			/* the sentence of the failure a handler is running on, place and all,
				 * NULL outside one. A bare RAISE sends it back out as it stands */
  int raising;			/* the exception a RAISE announced, -1 when the failure in hand came
				 * from the engine instead and the block reads its error code */
  bool positioned;		/* whether the error in hand already names where it was raised. The
				 * innermost statement that fails is the one that knows, and the blocks
				 * it travels out through must not name themselves instead */
  char *placed;			/* the sentence that named the place, kept bare for a caller that has
				 * to raise the error again */
  char *msg;			/* the same sentence without the place, which is what SQLERRM shows:
				 * the reference implementation answers with what the failure said,
				 * and only a RAISE makes that the exception's own wording */

  int call_depth;
  PLCSQL_FRAME *caller;
};

// XASL_STATE
typedef struct xasl_state XASL_STATE;
struct xasl_state
{
  VAL_DESCR vd;			/* Value Descriptor */
  QUERY_ID query_id;		/* Query associated with XASL */
  int qp_xasl_line;		/* Error line */
  /* A pointer, because nearly every qexec_* function carries this struct: outside a
   * procedure it stays NULL and neither the behaviour nor the cost of the existing paths
   * changes. */
  PLCSQL_FRAME *plcsql_frame;
};

extern qfile_list_id *qexec_execute_query (THREAD_ENTRY * thread_p, xasl_node * xasl, int dbval_cnt,
					   const DB_VALUE * dbval_ptr, QUERY_ID query_id);
extern int qexec_execute_mainblock (THREAD_ENTRY * thread_p, xasl_node * xasl, xasl_state * xstate,
				    UPDDEL_CLASS_INSTANCE_LOCK_INFO * p_class_instance_lock_info);
extern int qexec_execute_subquery_for_result_cache (THREAD_ENTRY * thread_p, xasl_node * xasl, xasl_state * xstate);
extern int qexec_start_mainblock_iterations (THREAD_ENTRY * thread_p, xasl_node * xasl, xasl_state * xstate);
extern int qexec_clear_xasl (THREAD_ENTRY * thread_p, xasl_node * xasl, bool is_final, bool for_parallel_aptr);
extern void qexec_clear_topn_items (THREAD_ENTRY * thread_p, xasl_node * xasl);
extern int qexec_clear_pred_context (THREAD_ENTRY * thread_p, pred_expr_with_context * pred_filter,
				     bool dealloc_dbvalues);
extern int qexec_clear_func_pred (THREAD_ENTRY * thread_p, func_pred * pred_filter);
extern int qexec_clear_partition_expression (THREAD_ENTRY * thread_p, regu_variable_node * expr);
extern int qexec_resolve_domains_for_aggregation_for_parallel_heap_scan_g_agg (THREAD_ENTRY * thread_p,
									       xasl_node * xasl, void *vd,
									       int *resolved);
extern int qexec_resolve_domains_for_aggregation_for_parallel_heap_scan_buildvalue_proc (THREAD_ENTRY * thread_p,
											 xasl_node * xasl, void *vd,
											 int *resolved);
extern int qexec_clear_xasl_for_parallel_aptr (THREAD_ENTRY * thread_p, xasl_node * xasl, bool is_final);
extern qfile_list_id *qexec_get_xasl_list_id (xasl_node * xasl);
extern xasl_state *qexec_deep_copy_xasl_state (THREAD_ENTRY * thread_p, xasl_state * xasl_state);
extern void qexec_free_xasl_state (THREAD_ENTRY * thread_p, xasl_state * xasl_state);
extern PLCSQL_FRAME *qexec_alloc_plcsql_frame (THREAD_ENTRY * thread_p, int locals_cnt, int cursors_cnt,
					       PLCSQL_FRAME * caller);
extern void qexec_free_plcsql_frame (THREAD_ENTRY * thread_p, PLCSQL_FRAME * frame);
extern int qexec_execute_plcsql (THREAD_ENTRY * thread_p, xasl_node * xasl, xasl_state * xstate);
extern int qexec_call_plcsql (THREAD_ENTRY * thread_p, xasl_node * xasl, DB_VALUE * args, int args_cnt,
			      DB_VALUE * result, char **placed_msg);
#if defined(CUBRID_DEBUG)
extern void get_xasl_dumper_linked_in ();
#endif

extern int qexec_clear_list_cache_by_class (THREAD_ENTRY * thread_p, const OID * class_oid);

#if defined(CUBRID_DEBUG)
extern bool qdump_check_xasl_tree (xasl_node * xasl);
#endif /* CUBRID_DEBUG */

extern int qexec_get_tuple_column_value (QFILE_TUPLE tpl, int index, DB_VALUE * valp, tp_domain * domain);
extern int qexec_insert_tuple_into_list (THREAD_ENTRY * thread_p, qfile_list_id * list_id,
					 valptr_list_node * outptr_list, val_descr * vd, qfile_tuple_record * tplrec);
extern void qexec_replace_prior_regu_vars_prior_expr (THREAD_ENTRY * thread_p, regu_variable_node * regu,
						      xasl_node * xasl, xasl_node * connect_by_ptr);
extern SCAN_CODE qexec_execute_scan_ptr (THREAD_ENTRY * thread_p, xasl_node * xasl, XASL_STATE * xasl_state,
					 void *scan_func_ptr);
extern int qexec_alloc_agg_hash_context_buildlist_xasl (THREAD_ENTRY * thread_p, xasl_node * xasl,
							XASL_STATE * xasl_state, bool not_use_membuf);
extern int qexec_hash_gby_agg_tuple_public (THREAD_ENTRY * thread_p, xasl_node * xasl, XASL_STATE * xasl_state,
					    QFILE_TUPLE_RECORD * tplrec, QFILE_TUPLE_DESCRIPTOR * tpldesc,
					    QFILE_LIST_ID * groupby_list, bool * output_tuple);
extern void qexec_mark_aggregate_operand_expressions (xasl_node * xasl);
extern int qexec_setup_topn_proc (THREAD_ENTRY * thread_p, xasl_node * xasl, VAL_DESCR * vd);
extern TOPN_STATUS qexec_add_tuple_to_topn (THREAD_ENTRY * thread_p, TOPN_TUPLES * topn_items,
					    QFILE_TUPLE_DESCRIPTOR * tpldescr);
extern int qexec_topn_tuples_to_list_id (THREAD_ENTRY * thread_p, xasl_node * xasl, XASL_STATE * xasl_state,
					 bool is_final, QFILE_LIST_ID * merged_results);
#endif /* _QUERY_EXECUTOR_H_ */
