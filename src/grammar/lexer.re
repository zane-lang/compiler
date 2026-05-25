#include "ast/.hpp"
#include "parser.tab.h"
#include <string>

static std::string toStr(const char* b, const char* e) {
	return std::string(b, static_cast<size_t>(e - b));
}

static std::string unescape(const char* b, const char* e) {
	std::string out;
	out.reserve(static_cast<size_t>(e - b));
	while (b < e) {
		if (*b == '\\' && b + 1 < e) {
			++b;
			switch (*b) {
				case '"':  out += '"';  break;
				case '\\': out += '\\'; break;
				case 'n':  out += '\n'; break;
				case 't':  out += '\t'; break;
				default:   out += '\\'; out += *b; break;
			}
		} else {
			out += *b;
		}
		++b;
	}
	return out;
}

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type*,
		const char*& cursor, const char*& marker, const char* limit,
		ast::nodes::Package*&) {
	for (;;) {
		if (cursor >= limit) return 0;
		const char* start = cursor;
		/*!re2c
		re2c:flags:utf-8     = 1;
		re2c:define:YYCTYPE  = "char";
		re2c:define:YYCURSOR = cursor;
		re2c:define:YYLIMIT  = limit;
		re2c:define:YYMARKER = marker;
		re2c:yyfill:enable   = 0;

		nonascii = [\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u00FF];
		ident    = [a-zA-Z_] | nonascii;
		str_char = [^"\\] | "\\" [^];
		// Digit groups: plain or swiss-separated (e.g. 1'000'000)
		digit     = [0-9];
		digits    = digit+;
		sw_digits = digit{1,3} ("'" digit{3})*;   // swiss thousands groups

		// INT: optional swiss grouping, no decimal point
		// FLOAT: optional swiss grouping, mandatory decimal point + fractional digits
		int_lit   = sw_digits | digits;
		float_lit = sw_digits "." digits | digits "." digits;
		operator_ = "+" | "-" | "*" | "/";

		[ \t\n]+       { continue; }
		"("            { return yy::Parser::token::LPAREN; }
		")"            { return yy::Parser::token::RPAREN; }
		"{"            { return yy::Parser::token::LCURLY; }
		"}"            { return yy::Parser::token::RCURLY; }
		","            { return yy::Parser::token::COMMA; }
		":"            { return yy::Parser::token::COLON; }

		"~"            { return yy::Parser::token::TILDE; }

		operator_ {
			yylval->emplace<std::string>(toStr(start, cursor));
			return yy::Parser::token::OPERATOR;
		}
		float_lit { 
			yylval->emplace<std::string>(toStr(start, cursor));
			return yy::Parser::token::FLOAT;
		}
		int_lit {
			yylval->emplace<std::string>(toStr(start, cursor));
			return yy::Parser::token::INT;
		}
		["] str_char* ["] { yylval->emplace<std::string>(unescape(start+1, cursor-1));
		                    return yy::Parser::token::STRING; }
		ident+         { yylval->emplace<std::string>(toStr(start, cursor));
		                 return yy::Parser::token::IDENT; }
		*              { return yy::Parser::token::ERROR; }
		*/
	}
}
