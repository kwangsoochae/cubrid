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
 * Companion to sp_grammar.y. Tokens are declared there, not here: until they exist a
 * character stands for itself.
 */

%{
#include "config.h"

#include "sp_grammar.h"
%}

%option noyywrap
%option nounput
%option noinput
%option never-interactive

%%

[ \t\r\n]+	{ }
.		{ return yytext[0]; }

%%
