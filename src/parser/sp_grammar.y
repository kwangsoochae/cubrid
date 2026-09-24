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
 * sp_grammar.y - PL/CSQL grammar file
 *
 * PL/CSQL keeps a grammar of its own rather than extending csql_grammar.y, so that its
 * keywords never reach an SQL context. The static SQL inside a procedure is parsed
 * afterwards by parser_parse_string (), never by a nested call from here - the SQL
 * parser is not reentrant.
 *
 * Expressions are not captured as text either: they are built here out of the same
 * PT_EXPR nodes an SQL expression becomes, so one type checker and one set of coercion
 * rules serve both languages.
 */

%{
#include "config.h"

#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "parser.h"
#include "parse_tree.h"
#include "parser_message.h"
#include "sp_parse.h"

/* The parser the nodes are allocated on, and the tree the driver hands back. Both belong
 * to one sp_parse_body () call: this grammar is no more reentrant than the SQL one. */
static PARSER_CONTEXT *sp_Parser = NULL;
static PT_NODE *sp_Result = NULL;

static void sp_yyerror (const char *s);
extern int sp_yylex (void);
extern int sp_yylineno;

typedef struct yy_buffer_state *SP_YY_BUFFER_STATE;
extern SP_YY_BUFFER_STATE sp_yy_scan_string (const char *str);
extern void sp_yy_delete_buffer (SP_YY_BUFFER_STATE buf);

static PT_NODE *sp_at (PT_NODE * node, int line, int column);
static PT_NODE *sp_make_stmt (PT_SP_STMT_OP op, int line, int column);
static void sp_unbound_char (PT_NODE * dt);
static PT_NODE *sp_make_loop (int form, PT_NODE * label, PT_NODE * name, PT_NODE * lower, PT_NODE * upper,
			      PT_NODE * body, int line, int column);
static PT_NODE *sp_make_cursor_op (PT_SP_STMT_OP op, const char *name, PT_NODE * args, int line, int column);
static PT_NODE *sp_make_cursor_attr (const char *name, int attr);
static PT_NODE *sp_make_reserved (int which);
static PT_NODE *sp_make_jump (PT_SP_STMT_OP op, PT_NODE * label, PT_NODE * cond, int line, int column);
static PT_NODE *sp_make_integer_literal (const char *text);
static PT_NODE *sp_make_real_literal (const char *text, int line, int column);
static PT_NODE *sp_make_null_literal (void);
static PT_NODE *sp_make_boolean_literal (bool value);
static PT_NODE *sp_make_typed_literal (PT_TYPE_ENUM type, const char *text);
static PT_NODE *sp_make_data_type (PT_TYPE_ENUM type, int precision, int scale);
static PT_NODE *sp_make_case (PT_NODE * operand, PT_NODE * when_list, PT_NODE * else_expr);
static PT_NODE *sp_as_condition (PT_NODE * operand);
static PT_NODE *sp_make_case_stmt (PT_NODE * selector, PT_NODE * arms, PT_NODE * else_body, int line, int column);

/* The location bison built for a rule, put on the node that rule returns. It is a macro
 * because @$ is only a location inside an action - bison rewrites it there, and would leave
 * it alone in a function of ours. */
#define SP_AT(node, loc)	sp_at ((node), (loc).first_line, (loc).first_column)
%}

%union
{
  PT_NODE *node;
  char *cptr;
  int number;
}

%token BEGIN_ CONSTANT_ CONTINUE_ DECLARE_ ELSE_ ELSIF_ END_ EXIT_ FOR_ IF_ IN_ LOOP_ NOT_ NULL_ REVERSE_
%token EXCEPTION_ OTHERS_ RAISE_ RAISE_APPLICATION_ERROR_ SQLCODE_ SQLERRM_
%token CASE_ FALSE_ THEN_ TRUE_ WHEN_ WHILE_
%token CLOSE_ CURSOR_ FETCH_ INTO_ OPEN_
%token AS_ AUTHID_ CREATE_ FUNCTION_ OUT_ PROCEDURE_ REPLACE_ RETURN_
%token AND_ DIV_ IS_ MOD_ OR_
%token ASSIGN DOTDOT CONCAT NE GE LE NULLSAFE_EQ LABEL_BEGIN LABEL_END
%token PERCENT_FOUND PERCENT_ISOPEN PERCENT_NOTFOUND PERCENT_ROWCOUNT PERCENT_ROWTYPE PERCENT_TYPE

%token <cptr> IDENT UNSIGNED_INTEGER UNSIGNED_REAL CHAR_STRING SQL_TEXT
%token <number> TYPE_KEYWORD

%type <node> block decl_list decl_list_opt decl stmt_list stmt if_stmt else_part_opt loop_stmt
%type <node> assign_stmt block_stmt null_stmt return_stmt return_opt expr expr_list_opt type_spec
%type <node> call_stmt sp_name arg_list_opt arg_list
%type <node> when_clause_list when_clause case_else_opt
%type <node> case_stmt case_stmt_arms case_stmt_arm case_stmt_else_opt
%type <node> jump_stmt label_decl_opt label_opt when_opt sql_stmt
%type <node> raise_stmt handler_part_opt handler_list handler handler_name_list
%type <node> cursor_decl cursor_params_opt open_stmt close_stmt fetch_stmt fetch_targets
%type <number> param_mode_opt
%type <node> routine param_list_opt param_list param
%type <number> constant_opt reverse_opt

%left OR_
%left AND_
%right NOT_
%nonassoc '=' NE '<' '>' LE GE NULLSAFE_EQ IS_
%left CONCAT
%left '+' '-'
%left '*' '/' DIV_ MOD_
%right UMINUS

/* A statement is placed where it begins rather than where the parser stood when the reduce
 * ran: by then the lookahead token has been read and sp_yylineno has moved past it. @$ takes
 * its start from the rule's first symbol, which is the statement's first token. */
%locations

%start sp_unit

%%

/* Either a bare body - the text after AS, which is what the catalog used to be cut down to -
 * or the whole routine as the catalog holds it. The first token tells them apart. Reading the
 * header is what gives a parameter its declared type, precision and all; the signature carries
 * only a DB_TYPE and the catalog's argument row no more than that. */
sp_unit
	: block
		{
		  sp_Result = $1;
		}
	| routine
		{
		  sp_Result = $1;
		}
	;

routine
	: CREATE_ or_replace_opt routine_kind sp_name param_list_opt return_opt authid_opt as_or_is block
		{
		  PT_NODE *node = $9;

		  if (node != NULL)
		    {
		      node->info.sp_stmt.params = $5;
		      node->info.sp_stmt.ret_type = $6;
		    }
		  $$ = node;
		}
	;

or_replace_opt
	: /* empty */
	| OR_ REPLACE_
	;

routine_kind
	: PROCEDURE_
	| FUNCTION_
	;

/* A function's declared result type. It rides on the body's block because that is what the
 * generator is handed, and a RETURN casts to it - the precision is here and nowhere else,
 * the same reason a parameter's is. */
return_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| RETURN_ type_spec
		{
		  sp_unbound_char ($2);
		  $$ = $2;
		}
	;

/* OWNER and CALLER are taken as identifiers rather than made keywords - they are ordinary
 * words and a body is free to name a variable either of them. */
authid_opt
	: /* empty */
	| AUTHID_ IDENT
	;

as_or_is
	: AS_
	| IS_
	;

param_list_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| '(' ')'
		{
		  $$ = NULL;
		}
	| '(' param_list ')'
		{
		  $$ = $2;
		}
	;

param_list
	: param
		{
		  $$ = $1;
		}
	| param_list ',' param
		{
		  $$ = parser_append_node ($3, $1);
		}
	;

/* The mode and a default are read and dropped. A parameter that is not IN, and one a call may
 * leave out, are not run here yet - what is wanted from the header today is the declared type. */
param
	: IDENT param_mode_opt type_spec param_default_opt
		{
		  PT_NODE *name = SP_AT (pt_name (sp_Parser, $1), @$);

		  if (name != NULL)
		    {
		      name->info.name.plcsql_param_mode = $2;
		      name->data_type = $3;
		      name->type_enum = ($3 != NULL) ? $3->type_enum : PT_TYPE_NONE;

		      sp_unbound_char (name->data_type);
		      name->type_enum = ($3 != NULL) ? $3->type_enum : PT_TYPE_NONE;
		    }
		  $$ = name;
		}
	;

/* A catalog routine's modes come from its signature, so what the header wrote is dropped for one.
 * A local routine has no signature, and a call has to know which of its arguments to give back,
 * so the mode is kept on the parameter. */
param_mode_opt
	: /* empty */
		{
		  $$ = PT_SP_PARAM_IN;
		}
	| IN_
		{
		  $$ = PT_SP_PARAM_IN;
		}
	| OUT_
		{
		  $$ = PT_SP_PARAM_OUT;
		}
	| IN_ OUT_
		{
		  $$ = PT_SP_PARAM_IN_OUT;
		}
	;

param_default_opt
	: /* empty */
	| ASSIGN expr
		{
		  parser_free_tree (sp_Parser, $2);
		}
	;

/* The body of a procedure: its declaration part is the text between AS and BEGIN, so it
 * carries no DECLARE. A block written as a statement does - see block_stmt. */
block
	: decl_list_opt BEGIN_ stmt_list handler_part_opt END_ semi_opt
		{
		  /* @$ takes its start from the first symbol, and an empty one is placed at the end
		   * of the token before the rule - so where the block begins is BEGIN when nothing
		   * was declared */
		  YYLTYPE at = ($1 != NULL) ? @1 : @2;
		  PT_NODE *node = sp_make_stmt (PT_SP_BLOCK, at.first_line, at.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.decl_list = $1;
		      node->info.sp_stmt.body = $3;
		      node->info.sp_stmt.else_body = $4;
		    }
		  $$ = node;
		}
	;

/* The EXCEPTION part of a block. The handlers are kept in the order they were written, because
 * the first one that names the exception is the one that runs. */
handler_part_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| EXCEPTION_ handler_list
		{
		  $$ = $2;
		}
	;

handler_list
	: handler
		{
		  $$ = $1;
		}
	| handler_list handler
		{
		  $$ = parser_append_node ($2, $1);
		}
	;

handler
	: WHEN_ handler_name_list THEN_ stmt_list
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_HANDLER, @$.first_line, @$.first_column);

		  if (node)
		    {
		      /* OTHERS names no exception, and the flag rides on the handler rather than on a
		       * name of its own so that the executor does not have to read a reserved word
		       * out of the name list */
		      node->info.sp_stmt.name = ($2 != NULL) ? $2 : NULL;
		      node->info.sp_stmt.flags = ($2 == NULL) ? PT_SP_HANDLER_OTHERS : 0;
		      node->info.sp_stmt.body = $4;
		    }
		  $$ = node;
		}
	;

/* One WHEN may name several exceptions. OTHERS cannot be one of them - it stands alone - and
 * the empty list is how this rule says so. */
handler_name_list
	: OTHERS_
		{
		  $$ = NULL;
		}
	| IDENT
		{
		  $$ = SP_AT (pt_name (sp_Parser, $1), @$);
		}
	| handler_name_list OR_ IDENT
		{
		  $$ = parser_append_node (SP_AT (pt_name (sp_Parser, $3), @3), $1);
		}
	;

decl_list_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| decl_list
		{
		  $$ = $1;
		}
	;

decl_list
	: decl
		{
		  $$ = $1;
		}
	| decl_list decl
		{
		  $$ = parser_append_node ($2, $1);
		}
	;

/* v bigint;   c constant int := 7;   e exception;   procedure p as begin ... end; */
decl
	: cursor_decl
	| routine_kind IDENT param_list_opt return_opt as_or_is block
		{
		  /* A local routine is declared where a variable is, and its body is an ordinary
		   * block - which is what makes the rule recursive, because a block has a
		   * declaration part of its own. The header is spelled the same way the top-level
		   * one is, so which kind it is reads off ret_type rather than the keyword. */
		  PT_NODE *node = sp_make_stmt (PT_SP_DECL, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.name = SP_AT (pt_name (sp_Parser, $2), @2);
		      node->info.sp_stmt.flags = PT_SP_DECL_ROUTINE;
		      node->info.sp_stmt.params = $3;
		      node->info.sp_stmt.ret_type = $4;
		      node->info.sp_stmt.body = $6;
		    }
		  $$ = node;
		}
	| IDENT EXCEPTION_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_DECL, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.name = SP_AT (pt_name (sp_Parser, $1), @$);
		      node->info.sp_stmt.flags = PT_SP_DECL_EXCEPTION;
		    }
		  $$ = node;
		}
	| IDENT constant_opt type_spec expr_list_opt ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_DECL, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.name = SP_AT (pt_name (sp_Parser, $1), @$);
		      node->info.sp_stmt.flags = $2;
		      node->data_type = $3;
		      node->type_enum = ($3 != NULL) ? $3->type_enum : PT_TYPE_NONE;
		      node->info.sp_stmt.expr = $4;
		    }
		  $$ = node;
		}
	;

/* A cursor is declared where a variable is, but it is not one: it holds no value and takes
 * no frame slot. Its query is gathered the way a statement's is - the lexer starts on SELECT
 * and reads to the semicolon - so the text arrives here already whole, semicolon included,
 * and the rule wants no ';' of its own. */
cursor_decl
	: CURSOR_ IDENT cursor_params_opt IS_ SQL_TEXT
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_CURSOR, @$.first_line, @$.first_column);

		  if (node != NULL)
		    {
		      node->info.sp_stmt.name = pt_name (sp_Parser, $2);
		      node->info.sp_stmt.params = $3;
		      node->info.sp_stmt.sql_text = $5;
		    }
		  $$ = node;
		}
	;

cursor_params_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| '(' param_list ')'
		{
		  $$ = $2;
		}
	;

open_stmt
	: OPEN_ IDENT ';'
		{
		  $$ = sp_make_cursor_op (PT_SP_OPEN, $2, NULL, @$.first_line, @$.first_column);
		}
	| OPEN_ IDENT '(' arg_list_opt ')' ';'
		{
		  $$ = sp_make_cursor_op (PT_SP_OPEN, $2, $4, @$.first_line, @$.first_column);
		}
	;

close_stmt
	: CLOSE_ IDENT ';'
		{
		  $$ = sp_make_cursor_op (PT_SP_CLOSE, $2, NULL, @$.first_line, @$.first_column);
		}
	;

fetch_stmt
	: FETCH_ IDENT INTO_ fetch_targets ';'
		{
		  $$ = sp_make_cursor_op (PT_SP_FETCH, $2, $4, @$.first_line, @$.first_column);
		}
	;

fetch_targets
	: IDENT
		{
		  $$ = SP_AT (pt_name (sp_Parser, $1), @$);
		}
	| fetch_targets ',' IDENT
		{
		  $$ = parser_append_node (SP_AT (pt_name (sp_Parser, $3), @$), $1);
		}
	;

type_spec
	: TYPE_KEYWORD
		{
		  $$ = SP_AT (sp_make_data_type ((PT_TYPE_ENUM) $1, DB_DEFAULT_PRECISION, DB_DEFAULT_SCALE), @$);
		}
	| TYPE_KEYWORD '(' UNSIGNED_INTEGER ')'
		{
		  $$ = SP_AT (sp_make_data_type ((PT_TYPE_ENUM) $1, atoi ($3), DB_DEFAULT_SCALE), @$);
		}
	| TYPE_KEYWORD '(' UNSIGNED_INTEGER ',' UNSIGNED_INTEGER ')'
		{
		  $$ = SP_AT (sp_make_data_type ((PT_TYPE_ENUM) $1, atoi ($3), atoi ($5)), @$);
		}
	;

constant_opt
	: /* empty */
		{
		  $$ = 0;
		}
	| CONSTANT_
		{
		  $$ = PT_SP_DECL_CONSTANT;
		}
	;

expr_list_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| ASSIGN expr
		{
		  $$ = $2;
		}
	;

stmt_list
	: stmt
		{
		  $$ = $1;
		}
	| stmt_list stmt
		{
		  $$ = parser_append_node ($2, $1);
		}
	;

stmt
	: assign_stmt
	| case_stmt
	| raise_stmt
	| call_stmt
	| if_stmt
	| loop_stmt
	| block_stmt
	| return_stmt
	| jump_stmt
	| sql_stmt
	| open_stmt
	| close_stmt
	| fetch_stmt
	| null_stmt
	;

/* The node under it is a PT_METHOD_CALL, the same one the SQL grammar builds for CALL, so
 * that pt_stored_procedure_to_regu () can lower it without knowing where it came from. */
call_stmt
	: sp_name '(' arg_list_opt ')' ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_CALL, @$.first_line, @$.first_column);
		  PT_NODE *call = SP_AT (parser_new_node (sp_Parser, PT_METHOD_CALL), @$);

		  if (node != NULL && call != NULL)
		    {
		      call->info.method_call.method_name = $1;
		      call->info.method_call.arg_list = $3;
		      call->info.method_call.call_or_expr = PT_IS_CALL_STMT;
		      node->info.sp_stmt.expr = call;
		    }
		  $$ = node;
		}
	;

sp_name
	: IDENT
		{
		  PT_NODE *name = SP_AT (pt_name (sp_Parser, $1), @$);

		  if (name != NULL)
		    {
		      PT_NAME_INFO_SET_FLAG (name, PT_NAME_INFO_USER_SPECIFIED);
		    }
		  $$ = name;
		}
	| IDENT '.' IDENT
		{
		  /* the qualifier goes to resolved and the routine to original, which is how the
		   * SQL grammar writes a dotted name (object_name) */
		  PT_NODE *name = SP_AT (pt_name (sp_Parser, $3), @$);

		  if (name != NULL)
		    {
		      name->info.name.resolved = pt_append_string (sp_Parser, NULL, $1);
		      PT_NAME_INFO_SET_FLAG (name, PT_NAME_INFO_USER_SPECIFIED);
		    }
		  $$ = name;
		}
	;

arg_list_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| arg_list
		{
		  $$ = $1;
		}
	;

arg_list
	: expr
		{
		  $$ = $1;
		}
	| arg_list ',' expr
		{
		  $$ = parser_append_node ($3, $1);
		}
	;

assign_stmt
	: IDENT ASSIGN expr ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_ASSIGN, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.name = SP_AT (pt_name (sp_Parser, $1), @$);
		      node->info.sp_stmt.expr = $3;
		    }
		  $$ = node;
		}
	;

/* A procedure returns without a value and a function with one. Which of the two was written
 * is not judged here: the PL/CSQL compiler has already refused a routine that gets it wrong,
 * so the body reaching this grammar is one it accepted. */
return_stmt
	: RETURN_ ';'
		{
		  $$ = sp_make_stmt (PT_SP_RETURN, @$.first_line, @$.first_column);
		}
	| RETURN_ expr ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_RETURN, @$.first_line, @$.first_column);

		  if (node != NULL)
		    {
		      node->info.sp_stmt.expr = $2;
		    }
		  $$ = node;
		}
	;

/* A bare RAISE re-raises what the handler it stands in is handling. Whether it stands in one is
 * not judged here - the PL/CSQL compiler has already refused a body that gets it wrong.
 *
 * RAISE_APPLICATION_ERROR is a third form of the same statement rather than a call: the name is
 * a keyword in the reference implementation's grammar too, which is why a body can hold it
 * without the catalog holding a routine under that name. */
raise_stmt
	: RAISE_ ';'
		{
		  $$ = sp_make_stmt (PT_SP_RAISE, @$.first_line, @$.first_column);
		}
	| RAISE_ IDENT ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_RAISE, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.name = SP_AT (pt_name (sp_Parser, $2), @2);
		    }
		  $$ = node;
		}
	| RAISE_APPLICATION_ERROR_ '(' expr ',' expr ')' ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_RAISE, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.flags |= PT_SP_RAISE_APP;
		      node->info.sp_stmt.expr = $3;
		      node->info.sp_stmt.expr2 = $5;
		    }
		  $$ = node;
		}
	;

null_stmt
	: NULL_ ';'
		{
		  $$ = sp_make_stmt (PT_SP_NULL_STMT, @$.first_line, @$.first_column);
		}
	;

block_stmt
	: DECLARE_ decl_list BEGIN_ stmt_list handler_part_opt END_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_BLOCK, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.flags = PT_SP_BLOCK_NESTED;
		      node->info.sp_stmt.decl_list = $2;
		      node->info.sp_stmt.body = $4;
		      node->info.sp_stmt.else_body = $5;
		    }
		  $$ = node;
		}
	| BEGIN_ stmt_list handler_part_opt END_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_BLOCK, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.flags = PT_SP_BLOCK_NESTED;
		      node->info.sp_stmt.body = $2;
		      node->info.sp_stmt.else_body = $3;
		    }
		  $$ = node;
		}
	;

/* The body reaches us as the text between AS and the end of the statement, and whether
 * that text keeps the final semicolon is the caller's business, not the grammar's. */
semi_opt
	: /* empty */
	| ';'
	;

/* An ELSIF becomes an IF of its own in the else branch, so the executor sees one shape. */
/* A CASE statement runs the statements of the first arm that matches. It is the IF chain it
 * stands for - see sp_make_case_stmt () - so nothing below the parser learns a new statement. */
case_stmt
	: CASE_ expr case_stmt_arms case_stmt_else_opt END_ CASE_ ';'
		{
		  $$ = sp_make_case_stmt ($2, $3, $4, @$.first_line, @$.first_column);
		  if ($$ == NULL)
		    {
		      YYERROR;
		    }
		}
	| CASE_ case_stmt_arms case_stmt_else_opt END_ CASE_ ';'
		{
		  $$ = sp_make_case_stmt (NULL, $2, $3, @$.first_line, @$.first_column);
		  if ($$ == NULL)
		    {
		      YYERROR;
		    }
		}
	;

/* each arm is a PT_SP_IF with its WHEN in expr and its THEN in body, not yet chained */
case_stmt_arms
	: case_stmt_arm
	| case_stmt_arms case_stmt_arm
		{
		  $$ = parser_append_node ($2, $1);
		}
	;

case_stmt_arm
	: WHEN_ expr THEN_ stmt_list
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_IF, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.expr = $2;
		      node->info.sp_stmt.body = $4;
		    }
		  $$ = node;
		}
	;

/* NULL when no ELSE was written, which sp_make_case_stmt () turns into CASE_NOT_FOUND */
case_stmt_else_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| ELSE_ stmt_list
		{
		  $$ = $2;
		}
	;

if_stmt
	: IF_ expr THEN_ stmt_list else_part_opt END_ IF_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_IF, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.expr = $2;
		      node->info.sp_stmt.body = $4;
		      node->info.sp_stmt.else_body = $5;
		    }
		  $$ = node;
		}
	;

else_part_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| ELSE_ stmt_list
		{
		  $$ = $2;
		}
	| ELSIF_ expr THEN_ stmt_list else_part_opt
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_IF, @$.first_line, @$.first_column);

		  if (node)
		    {
		      node->info.sp_stmt.expr = $2;
		      node->info.sp_stmt.body = $4;
		      node->info.sp_stmt.else_body = $5;
		    }
		  $$ = node;
		}
	;

/* The name after END LOOP is read and dropped. PL/CSQL does not require it to be the one the
 * loop opened with - a body naming a different one there is stored, so refusing it here would
 * refuse a body the engine already holds. */
loop_stmt
	: label_decl_opt LOOP_ stmt_list END_ LOOP_ label_opt ';'
		{
		  /* the loop's own keyword is where it begins when no label was written - see block */
		  YYLTYPE at = ($1 != NULL) ? @1 : @2;

		  $$ = sp_make_loop (PT_SP_LOOP_BASIC, $1, NULL, NULL, NULL, $3, at.first_line, at.first_column);
		}
	| label_decl_opt WHILE_ expr LOOP_ stmt_list END_ LOOP_ label_opt ';'
		{
		  YYLTYPE at = ($1 != NULL) ? @1 : @2;

		  $$ = sp_make_loop (PT_SP_LOOP_WHILE, $1, NULL, $3, NULL, $5, at.first_line, at.first_column);
		}
	| label_decl_opt FOR_ IDENT IN_ reverse_opt expr DOTDOT expr LOOP_ stmt_list END_ LOOP_ label_opt ';'
		{
		  YYLTYPE at = ($1 != NULL) ? @1 : @2;

		  $$ = sp_make_loop (PT_SP_LOOP_FOR | $5, $1, SP_AT (pt_name (sp_Parser, $3), @3), $6, $8, $10,
				     at.first_line, at.first_column);
		}
	;

label_decl_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| LABEL_BEGIN IDENT LABEL_END
		{
		  $$ = SP_AT (pt_name (sp_Parser, $2), @$);
		}
	;

label_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| IDENT
		{
		  $$ = SP_AT (pt_name (sp_Parser, $1), @$);
		}
	;

/* The SQL is carried as the text the lexer gathered. It is not parsed here: the SQL parser is
 * not reentrant and this one is running, so the text waits until this parse has returned. */
sql_stmt
	: SQL_TEXT
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_SQL, @$.first_line, @$.first_column);

		  if (node != NULL)
		    {
		      node->info.sp_stmt.sql_text = $1;
		    }
		  $$ = node;
		}
	;

/* EXIT and CONTINUE name the loop they act on, and a bare one acts on the innermost. The
 * condition is part of the statement rather than an IF around it because CONTINUE has no
 * branch to fall into: the loop goes on either way. */
jump_stmt
	: EXIT_ label_opt when_opt ';'
		{
		  $$ = sp_make_jump (PT_SP_EXIT, $2, $3, @$.first_line, @$.first_column);
		}
	| CONTINUE_ label_opt when_opt ';'
		{
		  $$ = sp_make_jump (PT_SP_CONTINUE, $2, $3, @$.first_line, @$.first_column);
		}
	;

when_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| WHEN_ expr
		{
		  $$ = $2;
		}
	;

reverse_opt
	: /* empty */
		{
		  $$ = 0;
		}
	| REVERSE_
		{
		  $$ = PT_SP_LOOP_REVERSE;
		}
	;

expr
	: IDENT PERCENT_FOUND
		{
		  $$ = SP_AT (sp_make_cursor_attr ($1, PT_SP_CURSOR_ATTR_FOUND), @$);
		}
	| IDENT PERCENT_NOTFOUND
		{
		  $$ = SP_AT (sp_make_cursor_attr ($1, PT_SP_CURSOR_ATTR_NOTFOUND), @$);
		}
	| IDENT PERCENT_ISOPEN
		{
		  $$ = SP_AT (sp_make_cursor_attr ($1, PT_SP_CURSOR_ATTR_ISOPEN), @$);
		}
	| IDENT PERCENT_ROWCOUNT
		{
		  $$ = SP_AT (sp_make_cursor_attr ($1, PT_SP_CURSOR_ATTR_ROWCOUNT), @$);
		}
	| SQLCODE_
		{
		  $$ = SP_AT (sp_make_reserved (PT_SP_RESERVED_SQLCODE), @$);
		}
	| SQLERRM_
		{
		  $$ = SP_AT (sp_make_reserved (PT_SP_RESERVED_SQLERRM), @$);
		}
	/* the operands of a logical operator are conditions - see sp_as_condition () */
	| expr OR_ expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_OR, sp_as_condition ($1), sp_as_condition ($3), NULL),
			      @$);
		}
	| expr AND_ expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_AND, sp_as_condition ($1), sp_as_condition ($3), NULL),
			      @$);
		}
	| NOT_ expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_NOT, sp_as_condition ($2), NULL, NULL), @$);
		}
	| expr '=' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_EQ, $1, $3, NULL), @$);
		}
	| expr NE expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_NE, $1, $3, NULL), @$);
		}
	| expr '<' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_LT, $1, $3, NULL), @$);
		}
	| expr '>' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_GT, $1, $3, NULL), @$);
		}
	| expr LE expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_LE, $1, $3, NULL), @$);
		}
	/* true when both sides are NULL, false when one is - never NULL itself, which is what the
	 * PL engine's opNullSafeEq gives and what the SQL operator of the same spelling does */
	| expr NULLSAFE_EQ expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_NULLSAFE_EQ, $1, $3, NULL), @$);
		}
	| expr GE expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_GE, $1, $3, NULL), @$);
		}
	| expr IS_ NULL_
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_IS_NULL, $1, NULL, NULL), @$);
		}
	| expr IS_ NOT_ NULL_
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_IS_NOT_NULL, $1, NULL, NULL), @$);
		}
	| expr CONCAT expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_STRCAT, $1, $3, NULL), @$);
		}
	| expr '+' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_PLUS, $1, $3, NULL), @$);
		}
	| expr '-' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_MINUS, $1, $3, NULL), @$);
		}
	| expr '*' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_TIMES, $1, $3, NULL), @$);
		}
	| expr '/' expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_DIVIDE, $1, $3, NULL), @$);
		}
	| expr MOD_ expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_MODULUS, $1, $3, NULL), @$);
		}
	| expr DIV_ expr
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_DIV, $1, $3, NULL), @$);
		}
	| '-' expr %prec UMINUS
		{
		  $$ = SP_AT (parser_make_expression (sp_Parser, PT_UNARY_MINUS, $2, NULL, NULL), @$);
		}
	| CASE_ when_clause_list case_else_opt END_
		{
		  $$ = SP_AT (sp_make_case (NULL, $2, $3), @$);
		}
	| CASE_ expr when_clause_list case_else_opt END_
		{
		  $$ = SP_AT (sp_make_case ($2, $3, $4), @$);
		}
	| '(' expr ')'
		{
		  $$ = $2;
		}
	| IDENT
		{
		  $$ = SP_AT (pt_name (sp_Parser, $1), @$);
		}
	/* A name with an argument list is the engine's own function where there is one of that
	 * name, and a call to a routine where there is not - which is the order the SQL grammar's
	 * generic_function reads it in, and the order that lets a body use SUBSTR without the
	 * catalog being asked about it. A qualified name is never a builtin: those have no owner.
	 * The call node is the same PT_METHOD_CALL the statement form builds, so
	 * pt_stored_procedure_to_regu () lowers it without knowing where it came from. */
	| sp_name '(' arg_list_opt ')'
		{
		  PT_NODE *call = NULL;

		  if (!PT_NAME_RESOLVED ($1))
		    {
		      call = parser_plcsql_builtin_func (sp_Parser, PT_NAME_ORIGINAL ($1), $3);
		    }

		  if (call == NULL)
		    {
		      call = parser_new_node (sp_Parser, PT_METHOD_CALL);
		      if (call != NULL)
			{
			  call->info.method_call.method_name = $1;
			  call->info.method_call.arg_list = $3;
			  call->info.method_call.call_or_expr = PT_IS_MTHD_EXPR;
			}
		    }
		  $$ = SP_AT (call, @$);
		}
	| UNSIGNED_INTEGER
		{
		  $$ = SP_AT (sp_make_integer_literal ($1), @$);
		}
	| UNSIGNED_REAL
		{
		  $$ = sp_make_real_literal ($1, @$.first_line, @$.first_column);
		}
	| CHAR_STRING
		{
		  $$ = SP_AT (pt_make_string_value (sp_Parser, $1), @$);
		}
	| NULL_
		{
		  $$ = SP_AT (sp_make_null_literal (), @$);
		}
	| TRUE_
		{
		  $$ = SP_AT (sp_make_boolean_literal (true), @$);
		}
	| FALSE_
		{
		  $$ = SP_AT (sp_make_boolean_literal (false), @$);
		}
	| TYPE_KEYWORD CHAR_STRING
		{
		  $$ = SP_AT (sp_make_typed_literal ((PT_TYPE_ENUM) $1, $2), @$);
		}
	;

/* One arm, built the same way for both forms: its WHEN part in arg3, its THEN part in arg1.
 * What that WHEN part means is sp_make_case ()'s to decide, which is what lets one rule and
 * one chaining loop serve both. */
when_clause_list
	: when_clause_list when_clause
		{
		  $$ = parser_append_node ($2, $1);
		}
	| when_clause
		{
		  $$ = $1;
		}
	;

when_clause
	: WHEN_ expr THEN_ expr
		{
		  PT_NODE *arm = parser_new_node (sp_Parser, PT_EXPR);

		  if (arm != NULL)
		    {
		      arm->info.expr.op = PT_CASE;
		      arm->info.expr.arg3 = $2;
		      arm->info.expr.arg1 = $4;
		    }
		  $$ = SP_AT (arm, @$);
		}
	;

case_else_opt
	: /* empty */
		{
		  $$ = NULL;
		}
	| ELSE_ expr
		{
		  $$ = $2;
		}
	;

%%

/*
 * sp_unbound_char () - read a routine's declared CHAR as a string
 *   return: nothing; the node is adjusted in place
 *   dt(in/out) : the PT_DATA_TYPE of a parameter or of what a function gives back, NULL when
 *                there is none
 *
 * note: a routine's types cannot be written with a length - CREATE refuses one - so there is no
 *       length for a value to fail to fit, and none to pad out to either. Measured against the
 *       PL engine: a DATETIME passed to a CHAR parameter arrives as its full text, a 7 arrives
 *       as "7", and a function declared to give back CHAR gives back 'char'. A CHAR domain
 *       would cut all three to one character, so it is read as VARCHAR at its full width. A
 *       variable declared CHAR is a different thing and keeps the one character the engine and
 *       the PL engine both give it.
 */
static void
sp_unbound_char (PT_NODE * dt)
{
  if (dt == NULL || dt->type_enum != PT_TYPE_CHAR)
    {
      return;
    }

  dt->type_enum = PT_TYPE_VARCHAR;
  dt->info.data_type.precision = DB_MAX_VARCHAR_PRECISION;
}

/*
 * sp_at () - place a node where the construct that built it begins
 *   return: the node it was handed, so that a call can be wrapped in place
 *   node(in/out) : NULL is passed through
 *   line(in)     :
 *   column(in)   :
 *
 * note: parser_new_node () already fills a position in, but from the SQL lexer's globals,
 *       which hold wherever the statement being compiled left them - a position in another
 *       text. Every node this grammar builds is placed again here.
 */
static PT_NODE *
sp_at (PT_NODE * node, int line, int column)
{
  if (node != NULL)
    {
      node->line_number = line;
      node->column_number = column;
    }

  return node;
}

/*
 * sp_make_stmt () - one procedural statement node on the parser in hand
 *   return: the node, NULL when the parser could not allocate one
 *   op(in)     : which statement
 *   line(in)   : where the statement begins, from the rule's @$
 *   column(in) :
 */
static PT_NODE *
sp_make_stmt (PT_SP_STMT_OP op, int line, int column)
{
  PT_NODE *node = parser_new_node (sp_Parser, PT_SP_STMT);

  if (node != NULL)
    {
      node->info.sp_stmt.op = op;
      sp_at (node, line, column);
    }

  return node;
}

/*
 * sp_make_loop () -
 *   return: the node, NULL when the parser could not allocate one
 *   form(in)  : which loop form, with the REVERSE bit already folded in
 *   name(in)  : the loop variable of a FOR, NULL otherwise
 *   lower(in) : the WHILE condition, or the lower bound of a FOR
 *   upper(in) : the upper bound of a FOR, NULL otherwise
 *   body(in)  : the statements
 *   line(in)  : where the loop begins, from the rule's @$
 *   column(in):
 */
static PT_NODE *
sp_make_loop (int form, PT_NODE * label, PT_NODE * name, PT_NODE * lower, PT_NODE * upper, PT_NODE * body,
	      int line, int column)
{
  PT_NODE *node = sp_make_stmt (PT_SP_LOOP, line, column);

  if (node != NULL)
    {
      node->info.sp_stmt.flags = form;
      node->info.sp_stmt.label = label;
      node->info.sp_stmt.name = name;
      node->info.sp_stmt.expr = lower;
      node->info.sp_stmt.expr2 = upper;
      node->info.sp_stmt.body = body;
    }

  return node;
}

/*
 * sp_make_cursor_op () - one OPEN or CLOSE node
 *   return: the node, NULL when the parser could not allocate one
 *   op(in)   : PT_SP_OPEN or PT_SP_CLOSE
 *   name(in) : the cursor's name as written
 *   args(in) : the arguments an OPEN passes, NULL for CLOSE and for an OPEN written without any
 *   line(in), column(in) : where the statement was written
 */
static PT_NODE *
sp_make_cursor_op (PT_SP_STMT_OP op, const char *name, PT_NODE * args, int line, int column)
{
  PT_NODE *node = sp_make_stmt (op, line, column);

  if (node != NULL)
    {
      node->info.sp_stmt.name = pt_name (sp_Parser, name);
      node->info.sp_stmt.expr = args;
    }

  return node;
}

/*
 * sp_make_cursor_attr () - one per cent attribute written on a cursor
 *   return: the node, NULL when the parser could not allocate one
 *   name(in) : the cursor's name as written
 *   attr(in) : which attribute, PT_SP_CURSOR_ATTR_*
 *
 * note: it is a PT_NAME rather than an expression because what it becomes is a frame slot -
 *       the cursor keeps one per attribute and FETCH writes them, so reading one is reading
 *       a local and needs nothing of its own below here.
 */
static PT_NODE *
sp_make_cursor_attr (const char *name, int attr)
{
  PT_NODE *node = pt_name (sp_Parser, name);

  if (node != NULL)
    {
      node->info.name.plcsql_cursor_attr = attr;
    }

  return node;
}

/*
 * sp_make_reserved () - SQLCODE or SQLERRM
 *   return: the node, NULL when the parser could not allocate one
 *   which(in) : PT_SP_RESERVED_SQLCODE or PT_SP_RESERVED_SQLERRM
 *
 * note: a PT_NAME for the same reason a cursor attribute is one - what it becomes is a frame
 *       slot, which a handler writes. They are words rather than identifiers so that a body
 *       cannot declare one or assign to one, which is how the PL engine reads them too.
 */
static PT_NODE *
sp_make_reserved (int which)
{
  PT_NODE *node = pt_name (sp_Parser, (which == PT_SP_RESERVED_SQLCODE) ? "sqlcode" : "sqlerrm");

  if (node != NULL)
    {
      node->info.name.plcsql_reserved = which;
    }

  return node;
}

/*
 * sp_make_jump () - one EXIT or CONTINUE node
 *   return: the node, NULL when the parser could not allocate one
 *   op(in)    : PT_SP_EXIT or PT_SP_CONTINUE
 *   label(in) : the loop it names, NULL when it names none and acts on the innermost
 *   cond(in)  : the WHEN condition, NULL when it was written without one
 *   line(in)  : where the statement begins, from the rule's @$
 *   column(in):
 */
static PT_NODE *
sp_make_jump (PT_SP_STMT_OP op, PT_NODE * label, PT_NODE * cond, int line, int column)
{
  PT_NODE *node = sp_make_stmt (op, line, column);

  if (node != NULL)
    {
      node->info.sp_stmt.label = label;
      node->info.sp_stmt.expr = cond;
    }

  return node;
}

/*
 * sp_make_data_type () - the declared type of a variable
 *   return: a PT_DATA_TYPE node, NULL when the parser could not allocate one
 *   type(in)      : which type the keyword named
 *   precision(in) : DB_DEFAULT_PRECISION when the declaration gave none
 *   scale(in)     : DB_DEFAULT_SCALE when the declaration gave none
 *
 * note: a character type takes the database charset and collation. PL/CSQL has no
 *       CHARSET or COLLATE clause on a declaration, so there is nothing else to take.
 */
static PT_NODE *
sp_make_data_type (PT_TYPE_ENUM type, int precision, int scale)
{
  PT_NODE *dt = parser_new_node (sp_Parser, PT_DATA_TYPE);
  int charset, coll_id;

  if (dt == NULL)
    {
      return NULL;
    }

  dt->type_enum = type;
  dt->info.data_type.precision = precision;
  dt->info.data_type.dec_precision = scale;

  if (precision == DB_DEFAULT_PRECISION)
    {
      switch (type)
	{
	case PT_TYPE_CHAR:
	  dt->info.data_type.precision = 1;
	  break;
	case PT_TYPE_VARCHAR:
	  dt->info.data_type.precision = DB_MAX_VARCHAR_PRECISION;
	  break;
	case PT_TYPE_NUMERIC:
	  dt->info.data_type.precision = DB_DEFAULT_NUMERIC_PRECISION;
	  dt->info.data_type.dec_precision = DB_DEFAULT_NUMERIC_SCALE;
	  break;
	default:
	  break;
	}
    }

  if (PT_IS_CHAR_STRING_TYPE (type))
    {
      if (pt_check_grammar_charset_collation (sp_Parser, NULL, NULL, &charset, &coll_id) == NO_ERROR)
	{
	  dt->info.data_type.units = charset;
	  dt->info.data_type.collation_id = coll_id;
	}
      else
	{
	  dt->info.data_type.units = -1;
	  dt->info.data_type.collation_id = -1;
	}
    }

  return dt;
}

/*
 * sp_as_condition () - an operand of AND, OR or NOT, in the shape the predicate builder reads
 *   return: operand itself when it is AND, OR or NOT already, otherwise (operand) = TRUE
 *   operand(in) : what was written on one side of the operator
 *
 * note: the predicate builder makes a condition of a PT_EXPR and a constant of anything else,
 *       from a field only a PT_VALUE has (xasl_generation.c, pt_to_pred_expr_local_with_arg ()).
 *       A boolean variable, a parameter or a function call written beside AND or OR was read
 *       that way, as whatever that field held, and so was a comparison once folding had made a
 *       NULL value of it (a = NULL), which came out false.
 *
 *       Compared with TRUE, an operand is the condition it stands for: true on true, false on
 *       false and unknown on NULL, and AND, OR and NOT then carry SQL's three-valued logic -
 *       which is the rule here, not the PL engine's "NULL when either side is" (the manual has
 *       the operators behave as they do in SQL). The comparison is kept from folding: folded, a
 *       NULL side would make a NULL value of it again and the constant would be back.
 */
static PT_NODE *
sp_as_condition (PT_NODE * operand)
{
  PT_NODE *eq, *yes;

  if (operand == NULL
      || (operand->node_type == PT_EXPR
	  && (operand->info.expr.op == PT_AND || operand->info.expr.op == PT_OR || operand->info.expr.op == PT_NOT)))
    {
      return operand;
    }

  eq = parser_new_node (sp_Parser, PT_EXPR);
  yes = sp_make_boolean_literal (true);
  if (eq == NULL || yes == NULL)
    {
      return operand;
    }
  eq->info.expr.op = PT_EQ;
  eq->info.expr.arg1 = operand;
  eq->info.expr.arg2 = yes;
  eq->flag.do_not_fold = 1;
  eq->line_number = operand->line_number;
  eq->column_number = operand->column_number;

  return eq;
}

/*
 * sp_make_case_stmt () - a CASE statement, as the IF chain it stands for
 *   return: the first IF, which is the whole statement; NULL after recording why it cannot be run
 *   selector(in)  : what was written between CASE and the first WHEN, NULL for the searched form.
 *                   It is consumed here
 *   arms(in)      : PT_SP_IF nodes in the order written, each with its WHEN in expr and its THEN
 *                   in body
 *   else_body(in) : the statements ELSE named, NULL when no ELSE was written
 *   line(in) / column(in) : where the statement begins
 *
 * note: the PL engine evaluates the selector once and compares it with each arm's value, and an
 *       arm is taken only when the comparison is true - so a NULL on either side takes none.
 *       Each arm here gets its own copy of the selector in an equality instead, which reads the
 *       same only when evaluating the selector again cannot give another answer. A name or a
 *       literal is taken; anything else is refused for now rather than run twice.
 *
 *       With no arm taken and no ELSE written the PL engine raises CASE_NOT_FOUND, so that is
 *       what the missing ELSE becomes. A searched arm's condition is left as written: IF takes
 *       its branch only on true, which is the reference implementation's rule as well.
 */
static PT_NODE *
sp_make_case_stmt (PT_NODE * selector, PT_NODE * arms, PT_NODE * else_body, int line, int column)
{
  PT_NODE *arm;

  if (arms == NULL)
    {
      return NULL;
    }

  if (selector != NULL)
    {
      if (selector->node_type != PT_NAME && selector->node_type != PT_VALUE)
	{
	  sp_yyerror ("a CASE statement's selector that is not a name or a literal is not run here yet");
	  return NULL;
	}

      for (arm = arms; arm != NULL; arm = arm->next)
	{
	  PT_NODE *eq = parser_new_node (sp_Parser, PT_EXPR);

	  if (eq == NULL)
	    {
	      return NULL;
	    }
	  eq->info.expr.op = PT_EQ;
	  eq->info.expr.arg1 = parser_copy_tree (sp_Parser, selector);
	  eq->info.expr.arg2 = arm->info.sp_stmt.expr;
	  eq->line_number = arm->info.sp_stmt.expr->line_number;
	  eq->column_number = arm->info.sp_stmt.expr->column_number;
	  arm->info.sp_stmt.expr = eq;
	}
      parser_free_node (sp_Parser, selector);
    }

  if (else_body == NULL)
    {
      else_body = sp_make_stmt (PT_SP_RAISE, line, column);
      if (else_body == NULL)
	{
	  return NULL;
	}
      else_body->info.sp_stmt.name = sp_at (pt_name (sp_Parser, "case_not_found"), line, column);
    }

  /* each arm's else is the next arm, the last arm's is ELSE */
  for (arm = arms; arm != NULL; arm = arm->next)
    {
      arm->info.sp_stmt.else_body = (arm->next != NULL) ? arm->next : else_body;
    }
  for (arm = arms; arm != NULL;)
    {
      PT_NODE *next = arm->next;

      arm->next = NULL;
      arm = next;
    }

  arms->line_number = line;
  arms->column_number = column;
  return arms;
}

/*
 * sp_make_case () - fold a CASE's arms into the chain the evaluator walks
 *   return: the first arm, which is the whole expression; NULL when there are no arms
 *   operand(in)   : the value written between CASE and the first WHEN, NULL for the searched
 *                   form. It is consumed here
 *   when_list(in) : the arms, in the order written, each holding its WHEN in arg3 and its
 *                   THEN in arg1
 *   else_expr(in) : what ELSE named, NULL when none was written
 *
 * note: a CASE is not one node but a list of them stood on end - each arm's arg2 is the next
 *       arm, so the evaluator that meets a false condition simply moves to arg2 and meets
 *       another PT_CASE. continued_case marks every arm but the first, which is how the
 *       evaluator tells a nested CASE apart from a continuation of this one. The last arm's
 *       arg2 takes ELSE, or an explicit NULL: the shape has no room for "nothing left to try",
 *       so the value that a CASE without ELSE yields has to be written out, and marked.
 *
 *       The two forms differ only in what an arm's WHEN part means. In the simple form it is a
 *       value, so each arm gets its own copy of the operand and an equality to compare them -
 *       copies rather than one shared node, because the arms are separate trees from here on
 *       and freeing one must not reach into another. This mirrors what the SQL grammar builds
 *       for CASE (csql_grammar.y), so everything below the parser meets the node shape it
 *       already knows.
 *
 *       In the searched form the WHEN part is a condition, and one that is not a comparison
 *       gets an equality against TRUE. What reads the condition builds a predicate from a
 *       PT_EXPR and, from anything else, a constant taken from a field only a PT_VALUE has
 *       (xasl_generation.c, pt_to_pred_expr_local_with_arg ()). A body may write a boolean
 *       where a condition goes - a variable, a parameter, a function call, any of them in
 *       parentheses - and such an arm was taken whatever the boolean held. The equality also
 *       leaves a NULL condition untaken, which is what the reference implementation does.
 */
static PT_NODE *
sp_make_case (PT_NODE * operand, PT_NODE * when_list, PT_NODE * else_expr)
{
  PT_NODE *arm, *next;

  if (when_list == NULL)
    {
      return NULL;
    }

  if (operand != NULL)
    {
      for (arm = when_list; arm != NULL; arm = arm->next)
	{
	  PT_NODE *eq = parser_new_node (sp_Parser, PT_EXPR);

	  if (eq == NULL)
	    {
	      return NULL;
	    }
	  eq->info.expr.op = PT_EQ;
	  eq->info.expr.arg1 = parser_copy_tree_list (sp_Parser, operand);
	  eq->info.expr.arg2 = arm->info.expr.arg3;
	  arm->info.expr.arg3 = eq;
	}
      parser_free_node (sp_Parser, operand);
    }
  else
    {
      for (arm = when_list; arm != NULL; arm = arm->next)
	{
	  PT_NODE *eq, *yes;

	  if (arm->info.expr.arg3->node_type == PT_EXPR)
	    {
	      continue;
	    }

	  eq = parser_new_node (sp_Parser, PT_EXPR);
	  yes = sp_make_boolean_literal (true);
	  if (eq == NULL || yes == NULL)
	    {
	      return NULL;
	    }
	  eq->info.expr.op = PT_EQ;
	  eq->info.expr.arg1 = arm->info.expr.arg3;
	  eq->info.expr.arg2 = yes;
	  arm->info.expr.arg3 = eq;
	}
    }

  when_list->info.expr.continued_case = 0;
  for (arm = when_list; (next = arm->next) != NULL; arm = next)
    {
      next->info.expr.continued_case = 1;
      arm->info.expr.arg2 = next;
      arm->next = NULL;
    }

  if (else_expr == NULL)
    {
      /* A CASE that matches nothing yields NULL, and the shape has nowhere to say so except
       * by standing a NULL in the last arg2. It has to be marked as the parser's own: an
       * unmarked NULL argument makes type checking give the whole expression the type NULL
       * (type_checking.c, does_op_specially_treat_null_arg () does not exempt PT_CASE), so
       * `CASE WHEN c THEN 'y' END` would come back typed NULL instead of the THEN's type. */
      else_expr = sp_make_null_literal ();
      if (else_expr != NULL)
	{
	  else_expr->flag.is_added_by_parser = 1;
	}
    }
  arm->info.expr.arg2 = else_expr;

  return when_list;
}

/*
 * sp_copy_token () - copy token text onto the parser the parse is running on
 *   return: the copy, NULL when there is no parse running
 *   text(in) :
 *
 * note: the lexer calls this instead of strdup so that the copy dies with the parser
 *       context, whether the parse succeeds or fails.
 */
char *
sp_copy_token (const char *text)
{
  if (sp_Parser == NULL)
    {
      return NULL;
    }

  return pt_append_string (sp_Parser, NULL, text);
}

/* The SQL text of the statement being crossed. One at a time: a statement is finished before
 * the next begins, and the parse is not reentrant. */
static PARSER_VARCHAR *sp_Sql_text = NULL;

/*
 * sp_sql_begin () - start gathering one SQL statement
 *   return:
 *   text(in) : the keyword that began it, which belongs to the statement
 */
void
sp_sql_begin (const char *text)
{
  sp_Sql_text = pt_append_nulstring (sp_Parser, NULL, text);
}

/*
 * sp_sql_add () - add what the scan just crossed
 *   return:
 *   text(in) :
 */
void
sp_sql_add (const char *text)
{
  sp_Sql_text = pt_append_nulstring (sp_Parser, sp_Sql_text, text);
}

/*
 * sp_sql_take () - the statement gathered so far, and start over
 *   return: the text on the parser, NULL when nothing was gathered
 */
char *
sp_sql_take (void)
{
  char *text = (sp_Sql_text != NULL) ? (char *) pt_get_varchar_bytes (sp_Sql_text) : NULL;

  sp_Sql_text = NULL;

  return text;
}

/*
 * sp_make_integer_literal () -
 *   return: a PT_VALUE node, NULL when the parser could not allocate one
 *   text(in) : the digits as written
 *
 * note: a literal too wide for INTEGER becomes NUMERIC, the way the SQL grammar widens it.
 */
static PT_NODE *
sp_make_integer_literal (const char *text)
{
  PT_NODE *val = parser_new_node (sp_Parser, PT_VALUE);
  long long int bigint;
  char *end;

  if (val == NULL)
    {
      return NULL;
    }

  val->info.value.text = pt_append_string (sp_Parser, NULL, text);

  errno = 0;
  bigint = strtoll (text, &end, 10);
  if (errno == ERANGE)
    {
      val->type_enum = PT_TYPE_NUMERIC;
      val->info.value.data_value.str =
	pt_append_bytes (sp_Parser, NULL, val->info.value.text, strlen (val->info.value.text));
    }
  else if (bigint > DB_INT32_MAX || bigint < DB_INT32_MIN)
    {
      val->type_enum = PT_TYPE_BIGINT;
      val->info.value.data_value.bigint = (DB_BIGINT) bigint;
    }
  else
    {
      val->type_enum = PT_TYPE_INTEGER;
      val->info.value.data_value.i = (int) bigint;
    }

  return val;
}

/*
 * sp_make_real_literal () -
 *   return: a PT_VALUE node, NULL when the parser could not allocate one
 *   text(in) : the number as written
 *   line(in) / column(in) : where it was written, for the error below to point at
 */
static PT_NODE *
sp_make_real_literal (const char *text, int line, int column)
{
  PT_NODE *val = sp_at (parser_new_node (sp_Parser, PT_VALUE), line, column);

  if (val == NULL)
    {
      return NULL;
    }

  val->info.value.text = pt_append_string (sp_Parser, NULL, text);

  if (strchr (text, 'e') != NULL || strchr (text, 'E') != NULL)
    {
      double d;

      /* the SQL grammar's own reading of a number too large to hold, down to the sentence:
       * without the check strtod () hands back an infinity and the body goes on computing
       * with it, which no CUBRID type has a value for */
      errno = 0;
      d = strtod (text, NULL);
      if (errno == ERANGE)
	{
	  PT_ERRORmf2 (sp_Parser, val, MSGCAT_SET_PARSER_SYNTAX, MSGCAT_SYNTAX_FLT_DBL_OVERFLOW, text,
		       pt_show_type_enum (PT_TYPE_DOUBLE));
	}

      val->type_enum = PT_TYPE_DOUBLE;
      val->info.value.data_value.d = d;
    }
  else
    {
      val->type_enum = PT_TYPE_NUMERIC;
      val->info.value.data_value.str =
	pt_append_bytes (sp_Parser, NULL, val->info.value.text, strlen (val->info.value.text));
    }

  return val;
}

/*
 * sp_make_null_literal () -
 *   return: a PT_VALUE node of type NULL, NULL when the parser could not allocate one
 */
static PT_NODE *
sp_make_null_literal (void)
{
  PT_NODE *val = parser_new_node (sp_Parser, PT_VALUE);

  if (val != NULL)
    {
      val->type_enum = PT_TYPE_NULL;
    }

  return val;
}

/*
 * sp_make_boolean_literal () - a TRUE or FALSE literal
 *   return: the PT_VALUE, NULL when the parser could not allocate one
 *   value(in) : which of the two was written
 */
static PT_NODE *
sp_make_boolean_literal (bool value)
{
  PT_NODE *node = parser_new_node (sp_Parser, PT_VALUE);

  if (node != NULL)
    {
      node->type_enum = PT_TYPE_LOGICAL;
      node->info.value.text = value ? "true" : "false";
      node->info.value.data_value.i = value ? 1 : 0;
    }

  return node;
}

/*
 * sp_make_typed_literal () - a DATE, TIME, TIMESTAMP or DATETIME literal
 *   return: the PT_VALUE, NULL when the type named cannot carry one
 *   type(in) : the type the keyword named
 *   text(in) : the text between the quotes, already folded by the lexer
 *
 * note: the node keeps the text and the type and nothing else, which is what the SQL grammar's
 *       own date_or_time_literal builds; what turns the one into the other is constant folding.
 *       PL/CSQL writes a literal of these four types only, so int'1' is a syntax error there
 *       and is refused here rather than built into a value of a type that cannot hold it.
 */
static PT_NODE *
sp_make_typed_literal (PT_TYPE_ENUM type, const char *text)
{
  PT_NODE *node;

  if (type != PT_TYPE_DATE && type != PT_TYPE_TIME && type != PT_TYPE_TIMESTAMP && type != PT_TYPE_DATETIME)
    {
      sp_yyerror ("a literal cannot be written with this type name");
      return NULL;
    }

  node = parser_new_node (sp_Parser, PT_VALUE);
  if (node != NULL)
    {
      node->type_enum = type;
      node->info.value.data_value.str = pt_append_bytes (sp_Parser, NULL, text, strlen (text));
      PT_NODE_PRINT_VALUE_TO_TEXT (sp_Parser, node);
    }

  return node;
}

/*
 * sp_yyerror () - record a syntax error on the parser in hand
 *   return:
 *   s(in) : the message bison built
 */
static void
sp_yyerror (const char *s)
{
  if (sp_Parser != NULL)
    {
      pt_record_error (sp_Parser, sp_Parser->statement_number, sp_yylloc.first_line, sp_yylloc.first_column,
		       s, NULL);
    }
}

/*
 * sp_parse_body () - parse the body of a PL/CSQL procedure
 *   return: the block node, NULL on a syntax error
 *   parser(in) : the parser the tree is allocated on. Errors are recorded on it
 *   body(in)   : the text between AS and the end of the procedure
 *
 * note: like the SQL parser this one is not reentrant, and neither may run inside the
 *       other. The static SQL of a procedure is parsed after this returns.
 */
PT_NODE *
sp_parse_body (PARSER_CONTEXT * parser, const char *body)
{
  SP_YY_BUFFER_STATE buffer;
  PT_NODE *result;
  int rc;

  if (parser == NULL || body == NULL)
    {
      return NULL;
    }

  /* one parse at a time - the globals below are the whole of the parser state */
  assert (sp_Parser == NULL);

  sp_Parser = parser;
  sp_Result = NULL;
  sp_yylineno = 1;
  sp_lexer_reset_position ();

  buffer = sp_yy_scan_string (body);
  if (buffer == NULL)
    {
      sp_Parser = NULL;
      return NULL;
    }

  rc = sp_yyparse ();
  sp_yy_delete_buffer (buffer);

  result = (rc == 0) ? sp_Result : NULL;

  sp_Parser = NULL;
  sp_Result = NULL;

  return result;
}
