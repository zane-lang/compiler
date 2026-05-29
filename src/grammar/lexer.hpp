#pragma once

#include "lexerint.h"
#include "str.h"
#include <string>

enum TokenCode {
	TOK_EOF = 0,
	TOK_LPAREN,
	TOK_RPAREN,
	TOK_LCURLY,
	TOK_RCURLY,
	TOK_COMMA,
	TOK_COLON,
	TOK_EQUAL,
	TOK_DOLLAR,
	TOK_THIN_ARROW,
	TOK_THICK_ARROW,
	TOK_AT,
	TOK_MUT,
	TOK_THIS,
	TOK_STRING,
	TOK_IDENT,
	TOK_INT,
	TOK_FLOAT,
	TOK_PLUS,
	TOK_MINUS,
	TOK_STAR,
	TOK_SLASH,
	TOK_TILDE,
	TOK_LINEBREAK,
	TOK_ERROR,
};

class Lexer : public LexerInterface {
public:
	Lexer(const std::string& sourcePath, const std::string& source);

	static void nextToken(LexerInterface* lex);
	virtual NextTokenFunc getTokenFunc() const override;
	virtual string tokenDesc() const override;
	virtual string tokenKindDesc(int kind) const override;

	void reportParseError() const;

	const std::string& sourcePath() const { return sourcePath_; }
	int tokenLine() const { return tokenLine_; }
	int tokenColumn() const { return tokenColumn_; }
	int tokenEndColumn() const { return tokenEndColumn_; }

private:
	std::string sourcePath_;
	const std::string& source_;
	const char* cursor_;
	const char* marker_;
	const char* limit_;
	const char* lineStart_;
	int line_;
	int tokenLine_;
	int tokenColumn_;
	int tokenEndColumn_;
	std::string currentLexeme_;

	int columnFor(const char* ptr) const;
	void updateLocation(const char* begin, const char* end);
	void setCurrentToken(int token, SemanticValue value, const char* begin, const char* end, int startLine, int startColumn);
	std::string describeToken(int token, SemanticValue value, const char* begin, const char* end) const;
	static const char* tokenName(int token);
};
