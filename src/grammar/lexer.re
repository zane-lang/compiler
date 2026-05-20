/*!re2c
re2c:define:YYCTYPE = "unsigned char";
re2c:define:YYCURSOR = cursor;
re2c:define:YYLIMIT = limit;
re2c:define:YYMARKER = marker;
re2c:yyfill:enable = 0;
*/

#include "ast/logic.hpp"
#include "parser.tab.h"
#include <string>

static std::string toStr(const char* b, const char* e) {
    return std::string(b, static_cast<size_t>(e - b));
}

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type*,
          const char*& cursor, const char*& marker, const char* limit) {
    for (;;) {
        if (cursor >= limit) return yy::Parser::token::END;
        const char* start = cursor;
        /*!re2c
        [ \t\n]+ { continue; }
        [0-9]+ {
            *yylval = ast::IntNode{std::stoi(toStr(start, cursor))};
            return yy::Parser::token::INT;
        }
        "+" { return yy::Parser::token::PLUS; }
        "(" { return yy::Parser::token::LPAREN; }
        ")" { return yy::Parser::token::RPAREN; }
        * { return yy::Parser::token::ERROR; }
        */
    }
}
