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

static void updateLocation(const char* begin, const char* end, int& line, const char*& line_start) {
	for (const char* cursor = begin; cursor < end; ++cursor) {
		if (*cursor == '\n') {
			++line;
			line_start = cursor + 1;
		}
	}
}

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type* yylloc,
		const char*& cursor, const char*& marker, const char* limit,
		const std::string&, ast::nodes::Package*&, int& line, const char*& line_start) {
	for (;;) {
		if (cursor >= limit) return 0;
		const char* start = cursor;

		yylloc->begin.line   = line;
		yylloc->begin.column = (int)(start - line_start) + 1;

		int tok = -1;

		/*!re2c
		re2c:flags:utf-8     = 1;
		re2c:define:YYCTYPE  = "char";
		re2c:define:YYCURSOR = cursor;
		re2c:define:YYLIMIT  = limit;
		re2c:define:YYMARKER = marker;
		re2c:yyfill:enable   = 0;

		nonascii  = [\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u00FF];
		ident     = [a-zA-Z_] | nonascii;
		str_char  = [^"\\] | "\\" [^];
		digit     = [0-9];
		digits    = digit+;
		sw_digits = digit{1,3} ("'" digit{3})*;
		int_lit   = sw_digits | digits;
		float_lit = sw_digits "." digits | digits "." digits;

		[ \t\r\n]+    {
			updateLocation(start, cursor, line, line_start);
			continue;
		}
		"("   { tok = yy::Parser::token::LPAREN;  goto done; }
		")"   { tok = yy::Parser::token::RPAREN;  goto done; }
		"{"   { tok = yy::Parser::token::LCURLY;  goto done; }
		"}"   { tok = yy::Parser::token::RCURLY;  goto done; }
		","   { tok = yy::Parser::token::COMMA;   goto done; }
		":"   { tok = yy::Parser::token::COLON;   goto done; }
		"~"   { tok = yy::Parser::token::TILDE;   goto done; }

		"+" { yylval->emplace<std::string>("+"); tok = yy::Parser::token::PLUS;  goto done; }
		"-" { yylval->emplace<std::string>("-"); tok = yy::Parser::token::MINUS; goto done; }
		"*" { yylval->emplace<std::string>("*"); tok = yy::Parser::token::STAR;  goto done; }
		"/" { yylval->emplace<std::string>("/"); tok = yy::Parser::token::SLASH; goto done; }

		"$"   { tok = yy::Parser::token::DOLLAR;  goto done; }
		"@"   { tok = yy::Parser::token::AT;  goto done; }
		"->"   { tok = yy::Parser::token::THIN_ARROW;  goto done; }

		float_lit {
			yylval->emplace<std::string>(toStr(start, cursor));
			tok = yy::Parser::token::FLOAT; goto done;
		}
		int_lit {
			yylval->emplace<std::string>(toStr(start, cursor));
			tok = yy::Parser::token::INT; goto done;
		}
		["] str_char* ["] {
			yylval->emplace<std::string>(unescape(start + 1, cursor - 1));
			tok = yy::Parser::token::STRING; goto done;
		}
		ident+ {
			yylval->emplace<std::string>(toStr(start, cursor));
			tok = yy::Parser::token::IDENT; goto done;
		}
		* { tok = yy::Parser::token::ERROR; goto done; }
		*/

		done:
		yylloc->end.line   = line;
		yylloc->end.column = (int)(cursor - line_start) + 1;
		return tok;
	}
}
