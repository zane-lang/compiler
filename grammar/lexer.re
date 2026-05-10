#include <cstdlib>
#include <cstring>
#include <iostream>

#include "lexer.hpp"
#include "parser.hpp"

static char* dupRange(const char* begin, const char* end) {
	const std::size_t size = static_cast<std::size_t>(end - begin);
	char* text = static_cast<char*>(std::malloc(size + 1));
	if (text == nullptr) {
		throw std::bad_alloc();
	}
	std::memcpy(text, begin, size);
	text[size] = '\0';
	return text;
}

int zane::Lexer::next(void* semanticValue) {
	YYSTYPE* semantic = static_cast<YYSTYPE*>(semanticValue);
	const char*& YYCURSOR = cursor();
	const char*& YYMARKER = marker();
	const char* YYLIMIT = limit();

	for (;;) {
		if (YYCURSOR >= YYLIMIT) {
			return 0;
		}

		const char* token = YYCURSOR;

		/*!re2c
		  re2c:define:YYCTYPE = char;
		  re2c:define:YYCURSOR = YYCURSOR;
		  re2c:define:YYLIMIT = YYLIMIT;
		  re2c:define:YYMARKER = YYMARKER;
		  re2c:yyfill:enable = 0;

		  [ \t\r\n]+ { continue; }
		  "///" [^\n]* ("\n" "///" [^\n]*)* "\n"? { continue; }
		  "//" [^\n]* "\n"? { continue; }

		  "package" { return PACKAGE; }
		  "import" { return IMPORT; }
		  "class" { return CLASS; }
		  "struct" { return STRUCT; }
		  "ref" { return REF; }
		  "implicit" { return IMPLICIT; }
		  "this" { return THIS; }
		  "mut" { return MUT; }
		  "if" { return IF; }
		  "elif" { return ELIF; }
		  "else" { return ELSE; }
		  "guard" { return GUARD; }
		  "loop" { return LOOP; }
		  "from" { return FROM; }
		  "to" { return TO; }
		  "return" { return RETURN; }
		  "abort" { return ABORT; }
		  "resolve" { return RESOLVE; }
		  "spawn" { return SPAWN; }
		  "init" { return INIT; }
		  "and" { return AND; }
		  "or" { return OR; }
		  "true" { return TRUE; }
		  "false" { return FALSE; }

		  "=>" { return FAT_ARROW; }
		  "->" { return ARROW; }
		  "??" { return QQ; }
		  "==" { return EQEQ; }
		  "~=" { return NEQ; }
		  "<=" { return LE; }
		  ">=" { return GE; }

		  "(" { return '('; }
		  ")" { return ')'; }
		  "{" { return '{'; }
		  "}" { return '}'; }
		  "[" { return '['; }
		  "]" { return ']'; }
		  "," { return ','; }
		  ":" { return ':'; }
		  "!" { return '!'; }
		  "." { return '.'; }
		  "?" { return '?'; }
		  "=" { return '='; }
		  "+" { return '+'; }
		  "-" { return '-'; }
		  "*" { return '*'; }
		  "/" { return '/'; }
		  "~" { return '~'; }
		  "<" { return '<'; }
		  ">" { return '>'; }
		  "|" { return '|'; }
		  "$" { return '$'; }
		  "@" { return '@'; }

		  "'" [A-Za-z_] [A-Za-z_0-9]* {
		  semantic->text = dupRange(token, YYCURSOR);
		  return TYPE_PARAM;
		  }
		  "\"" ([^"\\\n] | "\\" .)* "\"" {
		semantic->text = dupRange(token + 1, YYCURSOR - 1);
		return STRING;
	}
	[0-9]+ ("." [0-9]+)? {
		semantic->text = dupRange(token, YYCURSOR);
		return NUMBER;
	}
	[A-Za-z_] [A-Za-z_0-9]* {
		semantic->text = dupRange(token, YYCURSOR);
		return NAME;
	}
	* {
		std::cerr << "unexpected character: " << *token << '\n';
		return 0;
	}
	*/
	}
}

int yylex(YYSTYPE* yylval, zane::Lexer* lexer) {
	return lexer->next(yylval);
}
