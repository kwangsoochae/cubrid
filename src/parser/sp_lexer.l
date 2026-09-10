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
  {"begin", BEGIN_, PT_TYPE_NONE},
  {"bigint", TYPE_KEYWORD, PT_TYPE_BIGINT},
  {"char", TYPE_KEYWORD, PT_TYPE_CHAR},
  {"constant", CONSTANT_, PT_TYPE_NONE},
  {"date", TYPE_KEYWORD, PT_TYPE_DATE},
  {"datetime", TYPE_KEYWORD, PT_TYPE_DATETIME},
  {"decimal", TYPE_KEYWORD, PT_TYPE_NUMERIC},
  {"declare", DECLARE_, PT_TYPE_NONE},
  {"double", TYPE_KEYWORD, PT_TYPE_DOUBLE},
  {"else", ELSE_, PT_TYPE_NONE},
  {"elsif", ELSIF_, PT_TYPE_NONE},
  {"end", END_, PT_TYPE_NONE},
  {"float", TYPE_KEYWORD, PT_TYPE_FLOAT},
  {"for", FOR_, PT_TYPE_NONE},
  {"if", IF_, PT_TYPE_NONE},
  {"in", IN_, PT_TYPE_NONE},
  {"int", TYPE_KEYWORD, PT_TYPE_INTEGER},
  {"integer", TYPE_KEYWORD, PT_TYPE_INTEGER},
  {"is", IS_, PT_TYPE_NONE},
  {"loop", LOOP_, PT_TYPE_NONE},
  {"mod", MOD_, PT_TYPE_NONE},
  {"not", NOT_, PT_TYPE_NONE},
  {"null", NULL_, PT_TYPE_NONE},
  {"numeric", TYPE_KEYWORD, PT_TYPE_NUMERIC},
  {"or", OR_, PT_TYPE_NONE},
  {"reverse", REVERSE_, PT_TYPE_NONE},
  {"smallint", TYPE_KEYWORD, PT_TYPE_SMALLINT},
  {"string", TYPE_KEYWORD, PT_TYPE_VARCHAR},
  {"then", THEN_, PT_TYPE_NONE},
  {"time", TYPE_KEYWORD, PT_TYPE_TIME},
  {"timestamp", TYPE_KEYWORD, PT_TYPE_TIMESTAMP},
  {"varchar", TYPE_KEYWORD, PT_TYPE_VARCHAR},
  {"while", WHILE_, PT_TYPE_NONE}
};

static char *sp_unquote_string (const char *text);
static int sp_keyword_lookup (const char *text, PT_TYPE_ENUM * type);
%}

%option noyywrap
%option nounput
%option noinput
%option never-interactive
%option yylineno

%x COMMENT

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
".."			{ return DOTDOT; }
"||"			{ return CONCAT; }
"<>"			{ return NE; }
"!="			{ return NE; }
">="			{ return GE; }
"<="			{ return LE; }

{integer}		{ sp_yylval.cptr = sp_copy_token (yytext); return UNSIGNED_INTEGER; }
{real}			{ sp_yylval.cptr = sp_copy_token (yytext); return UNSIGNED_REAL; }

'([^']|'')*'		{ sp_yylval.cptr = sp_unquote_string (yytext); return CHAR_STRING; }

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
