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

static PT_NODE *sp_make_stmt (PT_SP_STMT_OP op);
static PT_NODE *sp_make_loop (int form, PT_NODE * name, PT_NODE * lower, PT_NODE * upper, PT_NODE * body);
static PT_NODE *sp_make_integer_literal (const char *text);
static PT_NODE *sp_make_real_literal (const char *text);
static PT_NODE *sp_make_null_literal (void);
static PT_NODE *sp_make_data_type (PT_TYPE_ENUM type, int precision, int scale);
%}

%union
{
  PT_NODE *node;
  char *cptr;
  int number;
}

%token BEGIN_ CONSTANT_ DECLARE_ ELSE_ ELSIF_ END_ FOR_ IF_ IN_ LOOP_ NOT_ NULL_ REVERSE_ THEN_ WHILE_
%token AND_ IS_ MOD_ OR_
%token ASSIGN DOTDOT CONCAT NE GE LE

%token <cptr> IDENT UNSIGNED_INTEGER UNSIGNED_REAL CHAR_STRING
%token <number> TYPE_KEYWORD

%type <node> block decl_list decl_list_opt decl stmt_list stmt if_stmt else_part_opt loop_stmt
%type <node> assign_stmt block_stmt null_stmt expr expr_list_opt type_spec
%type <node> call_stmt sp_name arg_list_opt arg_list
%type <number> constant_opt reverse_opt

%left OR_
%left AND_
%right NOT_
%nonassoc '=' NE '<' '>' LE GE IS_
%left CONCAT
%left '+' '-'
%left '*' '/' MOD_
%right UMINUS

%start sp_unit

%%

sp_unit
	: block
		{
		  sp_Result = $1;
		}
	;

/* The body of a procedure: its declaration part is the text between AS and BEGIN, so it
 * carries no DECLARE. A block written as a statement does - see block_stmt. */
block
	: decl_list_opt BEGIN_ stmt_list END_ semi_opt
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_BLOCK);

		  if (node)
		    {
		      node->info.sp_stmt.decl_list = $1;
		      node->info.sp_stmt.body = $3;
		    }
		  $$ = node;
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

/* v bigint;   c constant int := 7; */
decl
	: IDENT constant_opt type_spec expr_list_opt ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_DECL);

		  if (node)
		    {
		      node->info.sp_stmt.name = pt_name (sp_Parser, $1);
		      node->info.sp_stmt.flags = $2;
		      node->data_type = $3;
		      node->type_enum = ($3 != NULL) ? $3->type_enum : PT_TYPE_NONE;
		      node->info.sp_stmt.expr = $4;
		    }
		  $$ = node;
		}
	;

type_spec
	: TYPE_KEYWORD
		{
		  $$ = sp_make_data_type ((PT_TYPE_ENUM) $1, DB_DEFAULT_PRECISION, DB_DEFAULT_SCALE);
		}
	| TYPE_KEYWORD '(' UNSIGNED_INTEGER ')'
		{
		  $$ = sp_make_data_type ((PT_TYPE_ENUM) $1, atoi ($3), DB_DEFAULT_SCALE);
		}
	| TYPE_KEYWORD '(' UNSIGNED_INTEGER ',' UNSIGNED_INTEGER ')'
		{
		  $$ = sp_make_data_type ((PT_TYPE_ENUM) $1, atoi ($3), atoi ($5));
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
	| call_stmt
	| if_stmt
	| loop_stmt
	| block_stmt
	| null_stmt
	;

/* The node under it is a PT_METHOD_CALL, the same one the SQL grammar builds for CALL, so
 * that pt_stored_procedure_to_regu () can lower it without knowing where it came from. */
call_stmt
	: sp_name '(' arg_list_opt ')' ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_CALL);
		  PT_NODE *call = parser_new_node (sp_Parser, PT_METHOD_CALL);

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
		  PT_NODE *name = pt_name (sp_Parser, $1);

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
		  PT_NODE *name = pt_name (sp_Parser, $3);

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
		  PT_NODE *node = sp_make_stmt (PT_SP_ASSIGN);

		  if (node)
		    {
		      node->info.sp_stmt.name = pt_name (sp_Parser, $1);
		      node->info.sp_stmt.expr = $3;
		    }
		  $$ = node;
		}
	;

null_stmt
	: NULL_ ';'
		{
		  $$ = sp_make_stmt (PT_SP_NULL_STMT);
		}
	;

block_stmt
	: DECLARE_ decl_list BEGIN_ stmt_list END_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_BLOCK);

		  if (node)
		    {
		      node->info.sp_stmt.flags = PT_SP_BLOCK_NESTED;
		      node->info.sp_stmt.decl_list = $2;
		      node->info.sp_stmt.body = $4;
		    }
		  $$ = node;
		}
	| BEGIN_ stmt_list END_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_BLOCK);

		  if (node)
		    {
		      node->info.sp_stmt.flags = PT_SP_BLOCK_NESTED;
		      node->info.sp_stmt.body = $2;
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
if_stmt
	: IF_ expr THEN_ stmt_list else_part_opt END_ IF_ ';'
		{
		  PT_NODE *node = sp_make_stmt (PT_SP_IF);

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
		  PT_NODE *node = sp_make_stmt (PT_SP_IF);

		  if (node)
		    {
		      node->info.sp_stmt.expr = $2;
		      node->info.sp_stmt.body = $4;
		      node->info.sp_stmt.else_body = $5;
		    }
		  $$ = node;
		}
	;

loop_stmt
	: LOOP_ stmt_list END_ LOOP_ ';'
		{
		  $$ = sp_make_loop (PT_SP_LOOP_BASIC, NULL, NULL, NULL, $2);
		}
	| WHILE_ expr LOOP_ stmt_list END_ LOOP_ ';'
		{
		  $$ = sp_make_loop (PT_SP_LOOP_WHILE, NULL, $2, NULL, $4);
		}
	| FOR_ IDENT IN_ reverse_opt expr DOTDOT expr LOOP_ stmt_list END_ LOOP_ ';'
		{
		  $$ = sp_make_loop (PT_SP_LOOP_FOR | $4, pt_name (sp_Parser, $2), $5, $7, $9);
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
	: expr OR_ expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_OR, $1, $3, NULL);
		}
	| expr AND_ expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_AND, $1, $3, NULL);
		}
	| NOT_ expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_NOT, $2, NULL, NULL);
		}
	| expr '=' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_EQ, $1, $3, NULL);
		}
	| expr NE expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_NE, $1, $3, NULL);
		}
	| expr '<' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_LT, $1, $3, NULL);
		}
	| expr '>' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_GT, $1, $3, NULL);
		}
	| expr LE expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_LE, $1, $3, NULL);
		}
	| expr GE expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_GE, $1, $3, NULL);
		}
	| expr IS_ NULL_
		{
		  $$ = parser_make_expression (sp_Parser, PT_IS_NULL, $1, NULL, NULL);
		}
	| expr IS_ NOT_ NULL_
		{
		  $$ = parser_make_expression (sp_Parser, PT_IS_NOT_NULL, $1, NULL, NULL);
		}
	| expr CONCAT expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_STRCAT, $1, $3, NULL);
		}
	| expr '+' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_PLUS, $1, $3, NULL);
		}
	| expr '-' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_MINUS, $1, $3, NULL);
		}
	| expr '*' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_TIMES, $1, $3, NULL);
		}
	| expr '/' expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_DIVIDE, $1, $3, NULL);
		}
	| expr MOD_ expr
		{
		  $$ = parser_make_expression (sp_Parser, PT_MODULUS, $1, $3, NULL);
		}
	| '-' expr %prec UMINUS
		{
		  $$ = parser_make_expression (sp_Parser, PT_UNARY_MINUS, $2, NULL, NULL);
		}
	| '(' expr ')'
		{
		  $$ = $2;
		}
	| IDENT
		{
		  $$ = pt_name (sp_Parser, $1);
		}
	| UNSIGNED_INTEGER
		{
		  $$ = sp_make_integer_literal ($1);
		}
	| UNSIGNED_REAL
		{
		  $$ = sp_make_real_literal ($1);
		}
	| CHAR_STRING
		{
		  $$ = pt_make_string_value (sp_Parser, $1);
		}
	| NULL_
		{
		  $$ = sp_make_null_literal ();
		}
	;

%%

/*
 * sp_make_stmt () - one procedural statement node on the parser in hand
 *   return: the node, NULL when the parser could not allocate one
 *   op(in) : which statement
 */
static PT_NODE *
sp_make_stmt (PT_SP_STMT_OP op)
{
  PT_NODE *node = parser_new_node (sp_Parser, PT_SP_STMT);

  if (node != NULL)
    {
      node->info.sp_stmt.op = op;
      node->line_number = sp_yylineno;
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
 */
static PT_NODE *
sp_make_loop (int form, PT_NODE * name, PT_NODE * lower, PT_NODE * upper, PT_NODE * body)
{
  PT_NODE *node = sp_make_stmt (PT_SP_LOOP);

  if (node != NULL)
    {
      node->info.sp_stmt.flags = form;
      node->info.sp_stmt.name = name;
      node->info.sp_stmt.expr = lower;
      node->info.sp_stmt.expr2 = upper;
      node->info.sp_stmt.body = body;
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
 */
static PT_NODE *
sp_make_real_literal (const char *text)
{
  PT_NODE *val = parser_new_node (sp_Parser, PT_VALUE);

  if (val == NULL)
    {
      return NULL;
    }

  val->info.value.text = pt_append_string (sp_Parser, NULL, text);

  if (strchr (text, 'e') != NULL || strchr (text, 'E') != NULL)
    {
      val->type_enum = PT_TYPE_DOUBLE;
      val->info.value.data_value.d = strtod (text, NULL);
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
 * sp_yyerror () - record a syntax error on the parser in hand
 *   return:
 *   s(in) : the message bison built
 */
static void
sp_yyerror (const char *s)
{
  if (sp_Parser != NULL)
    {
      pt_record_error (sp_Parser, sp_Parser->statement_number, sp_yylineno, 0, s, NULL);
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
