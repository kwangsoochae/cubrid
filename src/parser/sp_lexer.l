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
 * sp_lexer.l - PL/CSQL lexer file
 *
 * Companion to sp_grammar.y. Identifiers and keywords share one pattern and are told
 * apart by a table lookup, so that a keyword stays case insensitive and the pattern set
 * does not grow with the language.
 */

%{
#include "config.h"

#include <stdlib.h>
#include <string.h>

#include "porting.h"
#include "parser.h"
#include "parse_tree.h"
#include "sp_grammar.h"
#include "sp_parse.h"

typedef struct sp_keyword SP_KEYWORD;
struct sp_keyword
{
  const char *name;
  int token;
  PT_TYPE_ENUM type;		/* the type a TYPE_KEYWORD names, PT_TYPE_NONE otherwise */
};

/* Sorted by name: sp_keyword_lookup () walks it with a binary search. */
static SP_KEYWORD sp_Keywords[] = {
  {"and", AND_, PT_TYPE_NONE},
  {"as", AS_, PT_TYPE_NONE},
  {"authid", AUTHID_, PT_TYPE_NONE},
  {"begin", BEGIN_, PT_TYPE_NONE},
  {"bigint", TYPE_KEYWORD, PT_TYPE_BIGINT},
  {"boolean", TYPE_KEYWORD, PT_TYPE_LOGICAL},
  {"case", CASE_, PT_TYPE_NONE},
  {"char", TYPE_KEYWORD, PT_TYPE_CHAR},
  {"character", TYPE_KEYWORD, PT_TYPE_CHAR},
  {"close", CLOSE_, PT_TYPE_NONE},
  {"constant", CONSTANT_, PT_TYPE_NONE},
  {"continue", CONTINUE_, PT_TYPE_NONE},
  {"create", CREATE_, PT_TYPE_NONE},
  {"cursor", CURSOR_, PT_TYPE_NONE},
  {"date", TYPE_KEYWORD, PT_TYPE_DATE},
  {"datetime", TYPE_KEYWORD, PT_TYPE_DATETIME},
  {"dec", TYPE_KEYWORD, PT_TYPE_NUMERIC},
  {"decimal", TYPE_KEYWORD, PT_TYPE_NUMERIC},
  {"declare", DECLARE_, PT_TYPE_NONE},
  {"div", DIV_, PT_TYPE_NONE},
  {"double", TYPE_KEYWORD, PT_TYPE_DOUBLE},
  {"else", ELSE_, PT_TYPE_NONE},
  {"elsif", ELSIF_, PT_TYPE_NONE},
  {"end", END_, PT_TYPE_NONE},
  {"exception", EXCEPTION_, PT_TYPE_NONE},
  {"exit", EXIT_, PT_TYPE_NONE},
  {"false", FALSE_, PT_TYPE_NONE},
  {"fetch", FETCH_, PT_TYPE_NONE},
  {"float", TYPE_KEYWORD, PT_TYPE_FLOAT},
  {"for", FOR_, PT_TYPE_NONE},
  {"function", FUNCTION_, PT_TYPE_NONE},
  {"if", IF_, PT_TYPE_NONE},
  {"in", IN_, PT_TYPE_NONE},
  {"int", TYPE_KEYWORD, PT_TYPE_INTEGER},
  {"integer", TYPE_KEYWORD, PT_TYPE_INTEGER},
  {"into", INTO_, PT_TYPE_NONE},
  {"is", IS_, PT_TYPE_NONE},
  {"loop", LOOP_, PT_TYPE_NONE},
  {"mod", MOD_, PT_TYPE_NONE},
  {"not", NOT_, PT_TYPE_NONE},
  {"null", NULL_, PT_TYPE_NONE},
  {"numeric", TYPE_KEYWORD, PT_TYPE_NUMERIC},
  {"open", OPEN_, PT_TYPE_NONE},
  {"or", OR_, PT_TYPE_NONE},
  {"others", OTHERS_, PT_TYPE_NONE},
  {"out", OUT_, PT_TYPE_NONE},
  {"procedure", PROCEDURE_, PT_TYPE_NONE},
  {"raise", RAISE_, PT_TYPE_NONE},
  {"real", TYPE_KEYWORD, PT_TYPE_FLOAT},
  {"replace", REPLACE_, PT_TYPE_NONE},
  {"return", RETURN_, PT_TYPE_NONE},
  {"reverse", REVERSE_, PT_TYPE_NONE},
  {"short", TYPE_KEYWORD, PT_TYPE_SMALLINT},
  {"smallint", TYPE_KEYWORD, PT_TYPE_SMALLINT},
  {"sqlcode", SQLCODE_, PT_TYPE_NONE},
  {"sqlerrm", SQLERRM_, PT_TYPE_NONE},
  {"string", TYPE_KEYWORD, PT_TYPE_VARCHAR},
  {"then", THEN_, PT_TYPE_NONE},
  {"time", TYPE_KEYWORD, PT_TYPE_TIME},
  {"timestamp", TYPE_KEYWORD, PT_TYPE_TIMESTAMP},
  {"true", TRUE_, PT_TYPE_NONE},
  {"varchar", TYPE_KEYWORD, PT_TYPE_VARCHAR},
  {"when", WHEN_, PT_TYPE_NONE},
  {"while", WHILE_, PT_TYPE_NONE}
};

static char *sp_unquote_string (const char *text);
static int sp_keyword_lookup (const char *text, PT_TYPE_ENUM * type);
static void sp_yy_user_action (void);

/* Byte offset of the character about to be read, and of the first character of the line it
 * sits on. A column is the distance between the two, counted from 1 - the same arithmetic
 * csql_grammar_scan.h names parser_column_position (). The line a token starts on is kept apart
 * from sp_yylineno because flex has already added the token's own newlines to sp_yylineno
 * by the time an action runs, which would put a literal written across two lines on the
 * line it ends. */
static int sp_buffer_pos;
static int sp_line_start_pos;
static int sp_token_start_line;

/* Every token in every start condition goes through this, so no rule carries position
 * bookkeeping of its own and a start condition added later is covered without being
 * touched - csql_lexer.l reaches every one of its own states the same way. */
#define YY_USER_ACTION	{ sp_yy_user_action (); }

/* flex's own output trips -Werror in a release build. csql_lexer.l carries the same
 * block and says why; this one exists because every generated scanner needs it. */
#if defined(__GNUC__) || defined(__clang__)
  #define BEGIN_SUPPRESS_WARNING_BISON_FLEX                \
    _Pragma("GCC diagnostic push")                         \
    _Pragma("GCC diagnostic ignored \"-Wsign-compare\"")   \
    _Pragma("GCC diagnostic ignored \"-Wredundant-decls\"")\
    _Pragma("GCC diagnostic ignored \"-Wimplicit-fallthrough=\"")

  #define END_SUPPRESS_WARNING_BISON_FLEX                  \
    _Pragma("GCC diagnostic pop")
#else
  #define BEGIN_SUPPRESS_WARNING_BISON_FLEX
  #define END_SUPPRESS_WARNING_BISON_FLEX
#endif

BEGIN_SUPPRESS_WARNING_BISON_FLEX
%}

%option noyywrap
%option nounput
%option noinput
%option never-interactive
%option yylineno

%x COMMENT
%x SQLTEXT

digit		[0-9]
letter		[A-Za-z_]
ident		{letter}({letter}|{digit})*
integer		{digit}+
real		{digit}+"."{digit}+([eE][+-]?{digit}+)?|"."{digit}+([eE][+-]?{digit}+)?|{digit}+[eE][+-]?{digit}+

%%

[ \t\r\n]+		{ }
"--"[^\n]*		{ }
"/*"			{ BEGIN (COMMENT); }
<COMMENT>"*/"		{ BEGIN (INITIAL); }
<COMMENT>.|\n		{ }

":="			{ return ASSIGN; }
"<<"			{ return LABEL_BEGIN; }
">>"			{ return LABEL_END; }
".."			{ return DOTDOT; }
"||"			{ return CONCAT; }
"<>"			{ return NE; }
"!="			{ return NE; }
">="			{ return GE; }
"<="			{ return LE; }

{integer}		{ sp_yylval.cptr = sp_copy_token (yytext); return UNSIGNED_INTEGER; }
{real}			{ sp_yylval.cptr = sp_copy_token (yytext); return UNSIGNED_REAL; }

'([^']|'')*'		{ sp_yylval.cptr = sp_unquote_string (yytext); return CHAR_STRING; }

	/* The type names that are two words, which is why they are here and not in the keyword
	 * table - that table looks a single word up. The letters are spelled out because the
	 * table's lookup is case-insensitive while these patterns are not, and these stand ahead
	 * of {ident} so that the longer match wins over the first word alone. */
[cC][hH][aA][rR]([aA][cC][tT][eE][rR])?[ \t\r\n]+[vV][aA][rR][yY][iI][nN][gG]	{
			  sp_yylval.number = (int) PT_TYPE_VARCHAR;
			  return TYPE_KEYWORD;
			}

[dD][oO][uU][bB][lL][eE][ \t\r\n]+[pP][rR][eE][cC][iI][sS][iI][oO][nN]	{
			  sp_yylval.number = (int) PT_TYPE_DOUBLE;
			  return TYPE_KEYWORD;
			}

	/* A cursor's attribute and a declaration's %TYPE are one family: a per cent sign and a
	 * word, which the reference implementation lexes as one token each and allows a space
	 * inside (PlcLexer.g4, PERCENT_*). Spelled out for the same reason the two-word type
	 * names above are - the keyword table looks up a single word. There is no token for a
	 * per cent sign on its own, here or there: the remainder operator is the word MOD. */
"%"[ \t\r\n]*[fF][oO][uU][nN][dD]		{ return PERCENT_FOUND; }
"%"[ \t\r\n]*[iI][sS][oO][pP][eE][nN]		{ return PERCENT_ISOPEN; }
"%"[ \t\r\n]*[nN][oO][tT][fF][oO][uU][nN][dD]	{ return PERCENT_NOTFOUND; }
"%"[ \t\r\n]*[rR][oO][wW][cC][oO][uU][nN][tT]	{ return PERCENT_ROWCOUNT; }
"%"[ \t\r\n]*[rR][oO][wW][tT][yY][pP][eE]	{ return PERCENT_ROWTYPE; }
"%"[ \t\r\n]*[tT][yY][pP][eE]			{ return PERCENT_TYPE; }

	/* A statement that begins with one of these is SQL, and the SQL parser reads it - not
	 * this one. The text is taken as written, up to the semicolon that ends it, because what
	 * is handed on has to be what the user typed: a hint lives in a comment and a name's
	 * spelling matters. REPLACE is missing from the list because it is this grammar's own
	 * keyword in CREATE OR REPLACE; taking it needs that pair read as one token first.
	 * A word that only starts one of these, selectfoo say, is an identifier - the longer
	 * match wins - but INSERT and TRUNCATE spelled exactly are also functions, and those
	 * forms are read as a statement here. Both were refused before this too. */
[sS][eE][lL][eE][cC][tT]|[iI][nN][sS][eE][rR][tT]|[uU][pP][dD][aA][tT][eE]|[dD][eE][lL][eE][tT][eE]|[mM][eE][rR][gG][eE]|[tT][rR][uU][nN][cC][aA][tT][eE]|[wW][iI][tT][hH]	{
			  sp_sql_begin (yytext);
			  BEGIN (SQLTEXT);
			}

	/* Inside the SQL the only things that have to be recognised are the ones that can hide a
	 * semicolon or a quote from the scan - a literal and the two comment forms. Everything
	 * else is copied through. */
<SQLTEXT>";"		{
			  BEGIN (INITIAL);
			  sp_yylval.cptr = sp_sql_take ();
			  return SQL_TEXT;
			}
<SQLTEXT>'([^']|'')*'	{ sp_sql_add (yytext); }
<SQLTEXT>"--"[^\n]*	{ sp_sql_add (yytext); }
<SQLTEXT>"/*"([^*]|\*+[^*/])*\*+"/"	{ sp_sql_add (yytext); }
<SQLTEXT>[^';/-]+	{ sp_sql_add (yytext); }
<SQLTEXT>.|\n		{ sp_sql_add (yytext); }

{ident}			{
			  PT_TYPE_ENUM type = PT_TYPE_NONE;
			  int token = sp_keyword_lookup (yytext, &type);

			  if (token == IDENT)
			    {
			      sp_yylval.cptr = sp_copy_token (yytext);
			    }
			  else if (token == TYPE_KEYWORD)
			    {
			      sp_yylval.number = (int) type;
			    }
			  return token;
			}

.			{ return yytext[0]; }

%%

END_SUPPRESS_WARNING_BISON_FLEX

/*
 * sp_yy_user_action () - place the token flex has just matched
 *   return:
 *
 * note: bison reads the location of the rule's first symbol out of this, which is what lets
 *       a statement be placed at where it begins rather than at the token whose arrival
 *       ended it.
 */
static void
sp_yy_user_action (void)
{
  if (YY_START == INITIAL)
    {
      /* a token scanned in an exclusive state is the continuation of one that opened in
       * INITIAL, so its start is the one already recorded */
      sp_yylloc.first_line = sp_token_start_line;
      sp_yylloc.first_column = sp_buffer_pos - sp_line_start_pos + 1;
    }

  if (sp_token_start_line < sp_yylineno)
    {
      const char *last_newline = strrchr (yytext, '\n');

      if (last_newline != NULL)
	{
	  sp_line_start_pos = sp_buffer_pos + (int) (last_newline - yytext) + 1;
	}
    }

  sp_buffer_pos += yyleng;
  sp_token_start_line = sp_yylineno;

  sp_yylloc.last_line = sp_yylineno;
  sp_yylloc.last_column = sp_buffer_pos - sp_line_start_pos + 1;
}

/*
 * sp_lexer_reset_position () - count from the first character of the body about to be read
 *   return:
 *
 * note: sp_parse_body () calls this beside its own reset of sp_yylineno. The scanner keeps
 *       these across calls the way flex keeps yylineno, so a second body would otherwise
 *       carry the first one's offsets.
 */
void
sp_lexer_reset_position (void)
{
  sp_buffer_pos = 0;
  sp_line_start_pos = 0;
  sp_token_start_line = 1;
}

/*
 * sp_unquote_string () - the literal's content, with its doubled quotes folded
 *   return: the copy, NULL when it could not be made
 *   text(in) : the literal as written, quotes included
 *
 * note: folded in place on the copy. The result only ever shrinks.
 */
static char *
sp_unquote_string (const char *text)
{
  char *copy = sp_copy_token (text);
  size_t len;
  size_t i, j;

  if (copy == NULL)
    {
      return NULL;
    }

  len = strlen (copy);
  for (i = 1, j = 0; i + 1 < len; i++)
    {
      copy[j++] = copy[i];
      if (copy[i] == '\'' && copy[i + 1] == '\'')
	{
	  i++;
	}
    }
  copy[j] = '\0';

  return copy;
}

/*
 * sp_keyword_lookup () - which token an identifier-shaped word carries
 *   return: the keyword's token, IDENT when the word is not one
 *   text(in) :
 *   type(out): the type a TYPE_KEYWORD names, untouched otherwise
 */
static int
sp_keyword_lookup (const char *text, PT_TYPE_ENUM * type)
{
  int low = 0;
  int high = (int) (sizeof (sp_Keywords) / sizeof (sp_Keywords[0])) - 1;

  while (low <= high)
    {
      int mid = (low + high) / 2;
      int cmp = strcasecmp (text, sp_Keywords[mid].name);

      if (cmp == 0)
	{
	  *type = sp_Keywords[mid].type;
	  return sp_Keywords[mid].token;
	}
      else if (cmp < 0)
	{
	  high = mid - 1;
	}
      else
	{
	  low = mid + 1;
	}
    }

  return IDENT;
}
