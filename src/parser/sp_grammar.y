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
 */

%{
#include "config.h"

static void sp_yyerror (const char *s);
extern int sp_yylex (void);
%}

%start sp_unit

%%

/* Nothing routes here yet. The rules arrive with the entry point that calls them. */
sp_unit
	: /* empty */
	;

%%

static void
sp_yyerror (const char *s)
{
  /* A diagnostic needs the parser context that the caller will own. */
  (void) s;
}
