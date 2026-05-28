#include "grammar/lexer.hpp"
#include "useract.h"
#include <iostream>
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

static std::string findLine(const std::string& source, int lineNumber) {
	int currentLine = 1;
	size_t lineStart = 0;

	while (lineStart <= source.size()) {
		size_t lineEnd = source.find('\n', lineStart);
		if (lineEnd == std::string::npos)
			lineEnd = source.size();

		if (currentLine == lineNumber)
			return source.substr(lineStart, lineEnd - lineStart);

		if (lineEnd == source.size())
			break;

		lineStart = lineEnd + 1;
		++currentLine;
	}

	return std::string();
}

Lexer::Lexer(const std::string& sourcePath, const std::string& source)
	: sourcePath_(sourcePath),
	  source_(source),
	  cursor_(source.c_str()),
	  marker_(source.c_str()),
	  limit_(source.c_str() + source.size()),
	  lineStart_(source.c_str()),
	  line_(1),
	  tokenLine_(1),
	  tokenColumn_(1),
	  tokenEndColumn_(1) {
	type = TOK_EOF;
	sval = NULL_SVAL;
	loc = SL_UNKNOWN;
}

LexerInterface::NextTokenFunc Lexer::getTokenFunc() const {
	return &Lexer::nextToken;
}

int Lexer::columnFor(const char* ptr) const {
	return static_cast<int>(ptr - lineStart_) + 1;
}

void Lexer::updateLocation(const char* begin, const char* end) {
	for (const char* cursor = begin; cursor < end; ++cursor) {
		if (*cursor == '\n') {
			++line_;
			lineStart_ = cursor + 1;
		}
	}
}

void Lexer::setCurrentToken(int token, SemanticValue value, const char* begin, const char* end, int startLine, int startColumn) {
	updateLocation(begin, end);
	type = token;
	sval = value;
	loc = SL_UNKNOWN;
	tokenLine_ = startLine;
	tokenColumn_ = startColumn;
	tokenEndColumn_ = columnFor(end);
	currentLexeme_ = describeToken(token, value, begin, end);
}

std::string Lexer::describeToken(int token, SemanticValue value, const char* begin, const char* end) const {
	if (token == TOK_STRING || token == TOK_IDENT || token == TOK_INT || token == TOK_FLOAT) {
		const auto* text = reinterpret_cast<std::string*>(value);
		return text != nullptr ? *text : std::string();
	}

	if (token == TOK_EOF)
		return std::string();

	return toStr(begin, end);
}

const char* Lexer::tokenName(int token) {
	switch (token) {
		case TOK_EOF: return "end of file";
		case TOK_LPAREN: return "(";
		case TOK_RPAREN: return ")";
		case TOK_LCURLY: return "{";
		case TOK_RCURLY: return "}";
		case TOK_COMMA: return ",";
		case TOK_COLON: return ":";
		case TOK_EQUAL: return "=";
		case TOK_DOLLAR: return "$";
		case TOK_THIN_ARROW: return "->";
		case TOK_THICK_ARROW: return "=>";
		case TOK_AT: return "@";
		case TOK_MUT: return "mut";
		case TOK_THIS: return "this";
		case TOK_STRING: return "string";
		case TOK_IDENT: return "identifier";
		case TOK_INT: return "int";
		case TOK_FLOAT: return "float";
		case TOK_PLUS: return "+";
		case TOK_MINUS: return "-";
		case TOK_STAR: return "*";
		case TOK_SLASH: return "/";
		case TOK_TILDE: return "~";
		case TOK_ERROR: return "invalid token";
		default: return "unknown token";
	}
}

string Lexer::tokenDesc() const {
	if (type == TOK_EOF)
		return string("end of file");

	if (type == TOK_STRING || type == TOK_IDENT || type == TOK_INT || type == TOK_FLOAT)
		return string(currentLexeme_.c_str());

	return string(tokenName(type));
}

string Lexer::tokenKindDesc(int kind) const {
	return string(tokenName(kind));
}

void Lexer::reportParseError() const {
	std::cerr << sourcePath_ << ":" << tokenLine_ << ":" << tokenColumn_ << ": error: unexpected "
		<< (type == TOK_EOF ? "end of file" : currentLexeme_) << "\n";

	const std::string line = findLine(source_, tokenLine_);
	if (line.empty())
		return;

	const std::string lineNumber = std::to_string(tokenLine_);
	std::cerr << lineNumber << " | " << line << "\n";

	std::string caretLine;
	caretLine.reserve(lineNumber.size() + 3 + line.size());
	caretLine.append(lineNumber.size(), ' ');
	caretLine += " | ";
	for (int column = 1; column < tokenColumn_; ++column)
		caretLine += static_cast<size_t>(column - 1) < line.size() && line[static_cast<size_t>(column - 1)] == '\t' ? '\t' : ' ';

	const int highlightWidth = std::max(1, tokenEndColumn_ - tokenColumn_);
	caretLine.append(static_cast<size_t>(highlightWidth), '^');
	std::cerr << caretLine << "\n";
}

void Lexer::nextToken(LexerInterface* base) {
	auto* lexer = static_cast<Lexer*>(base);
	for (;;) {
		if (lexer->cursor_ >= lexer->limit_) {
			lexer->type = TOK_EOF;
			lexer->sval = NULL_SVAL;
			lexer->loc = SL_UNKNOWN;
			lexer->tokenLine_ = lexer->line_;
			lexer->tokenColumn_ = lexer->columnFor(lexer->cursor_);
			lexer->tokenEndColumn_ = lexer->tokenColumn_;
			lexer->currentLexeme_.clear();
			return;
		}

		const char* start = lexer->cursor_;
		const int startLine = lexer->line_;
		const int startColumn = lexer->columnFor(start);
		int tok = TOK_ERROR;
		SemanticValue sval = NULL_SVAL;

		#define cursor lexer->cursor_
		#define marker lexer->marker_
		#define limit lexer->limit_

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
			lexer->updateLocation(start, cursor);
			continue;
		}
		"="   { tok = TOK_EQUAL;   goto done; }
		"("   { tok = TOK_LPAREN;  goto done; }
		")"   { tok = TOK_RPAREN;  goto done; }
		"{"   { tok = TOK_LCURLY;  goto done; }
		"}"   { tok = TOK_RCURLY;  goto done; }
		","   { tok = TOK_COMMA;   goto done; }
		":"   { tok = TOK_COLON;   goto done; }
		"~"   { tok = TOK_TILDE;   goto done; }
		"+"   { tok = TOK_PLUS;    goto done; }
		"-"   { tok = TOK_MINUS;   goto done; }
		"*"   { tok = TOK_STAR;    goto done; }
		"/"   { tok = TOK_SLASH;   goto done; }

		"$"    { tok = TOK_DOLLAR;      goto done; }
		"@"    { tok = TOK_AT;          goto done; }
		"->"   { tok = TOK_THIN_ARROW;  goto done; }
		"=>"   { tok = TOK_THICK_ARROW; goto done; }

		float_lit {
			sval = reinterpret_cast<SemanticValue>(new std::string(toStr(start, cursor)));
			tok = TOK_FLOAT; goto done;
		}
		int_lit {
			sval = reinterpret_cast<SemanticValue>(new std::string(toStr(start, cursor)));
			tok = TOK_INT; goto done;
		}
		["] str_char* ["] {
			sval = reinterpret_cast<SemanticValue>(new std::string(unescape(start + 1, cursor - 1)));
			tok = TOK_STRING; goto done;
		}
		"mut"  { tok = TOK_MUT;  goto done; }
		"this" { tok = TOK_THIS; goto done; }
		ident+ {
			sval = reinterpret_cast<SemanticValue>(new std::string(toStr(start, cursor)));
			tok = TOK_IDENT; goto done;
		}
		* {
			tok = TOK_ERROR;
			goto done;
		}
		*/

		done:
		#undef cursor
		#undef marker
		#undef limit

		lexer->setCurrentToken(tok, sval, start, lexer->cursor_, startLine, startColumn);
		return;
	}
}
