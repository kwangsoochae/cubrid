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
 * sp_parse.h - the entry point of the PL/CSQL parser
 */

#ifndef _SP_PARSE_H_
#define _SP_PARSE_H_

#ident "$Id$"

#if defined (SERVER_MODE)
#error Does not belong to server module
#endif /* defined (SERVER_MODE) */

#include "parse_tree.h"

#ifdef __cplusplus
extern "C"
{
#endif

  extern PT_NODE *sp_parse_body (PARSER_CONTEXT * parser, const char *body);

/* For sp_lexer.l: token text copied onto the parser of the running parse. */
  extern char *sp_copy_token (const char *text);

#ifdef __cplusplus
}
#endif

#endif				/* _SP_PARSE_H_ */
