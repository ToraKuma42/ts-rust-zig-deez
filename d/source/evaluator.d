/**
 * Evaluator structures based on the awesome book
 * "Writing an Interpreter in Go" by Thorsten Ball.
 *
 * Authors: ToraKuma42
 * License: MIT
 * Version: 0.0.1
 */

import atom;
import expression;
import parser;
import quote;

import std.algorithm.iteration : joiner;
import std.algorithm.mutation : remove;
import std.array : appender, Appender, empty;
import std.conv : to;
import std.format : format;
import std.traits : isInstanceOf;

import std.range : enumerate;
import std.sumtype : match;

/// Evaluates expressions and statement nodes
struct Evaluator {
private:
    Parser parser; /// Stores statement nodes for evaluation
    Environment* env; /// Environment for variables and definitions
    Environment* macroEnv; /// Environment for macros
    StatementNode[] progStatements; /// Program statements
    ulong position; /// Current statement cursor
    ulong statementCount; /// Cached statement count
public:
    Appender!(EvalResult[]) results; /// Results from each program statement

    /**
     * Constucts the evaluator.
     * Params:
     * parser = the parser with statements to evaluate
     * env = the environment
     * macroEnv = the macro environment
     */
    this(ref Parser parser, Environment* env, Environment* macroEnv)
    {
        this.parser = parser;
        this.env = env;
        this.macroEnv = macroEnv;
        this.results = appender!(EvalResult[]);
        this.position = 0;
        this.progStatements = parser.program.statements[];
        this.statementCount = progStatements.length;
    }

    /**
     * Constucts the evaluator from the checkpoint.
     * Params:
     * parser = the parser with statements to evaluate
     * env = the main environment
     * macroEnv = the macro environment
     * position = the starting statement
     */
    this(ref Parser parser, Environment* env, Environment* macroEnv, ulong position)
    {
        this.parser = parser;
        this.env = env;
        this.macroEnv = macroEnv;
        this.results = appender!(EvalResult[]);
        this.position = position;
        this.progStatements = parser.program.statements[];
        this.statementCount = progStatements.length;
    }

    /// Add macros in its own environment
    void defineMacros()
    {
        auto definitions = appender!(ulong[]);

        for (ulong i = this.position; i < this.statementCount; i++) {
            auto statement = this.progStatements[i];

            // Check if statement is macro definition
            auto letStatement = cast(LetStatement)(statement);

            if (letStatement !is null) {
                auto macroLiteral = cast(MacroLiteralNode)(letStatement.expr);

                if (macroLiteral !is null) {
                    // Add macro
                    auto macroNode = Macro(&macroLiteral.parameters,
                            &macroLiteral.macroBody, this.macroEnv);
                    auto key = letStatement.varName(this.parser.lexer);
                    this.macroEnv.items[key] = macroNode;

                    definitions.put(i);
                }
            }
        }

        // TODO: Find faster delete in place
        auto defArray = definitions[];
        foreach_reverse (idx; defArray) {
            this.progStatements.remove(idx);
        }

        if (!defArray.empty) {
            parser.program.statements = this.progStatements.appender();
        }
    }

    /// Expand every macro in the program
    void expandMacros()
    {
        for (ulong i = this.position; i < this.statementCount; i++) {
            this.progStatements[i] = modifyStatement(this.progStatements[i],
                    this.parser.lexer, this.macroEnv, &modifyAndExpandMacro).match!(
                    (StatementNode st) => st, _ => assert(false,
                    "Cannot modify non-statement node during macro expansion"));
        }
    }

    /// Evaluate the entire program
    void evalProgram()
    {
        bool notReturned = true;

        while ((this.position < this.statementCount) && notReturned) {
            auto res = evalStatement(progStatements[this.position], this.parser.lexer, this.env);

            notReturned = res.match!((ReturnValue _) => false, (ErrorValue _) => false, _ => true);

            this.results.put(res);
            this.position++;
        }
    }

    /// Print end result of program
    string showResult()
    {
        auto finalResults = results[];

        if (finalResults.empty()) {
            return "";
        } else {
            auto endResult = finalResults[$ - 1];

            return endResult.match!((ResultMap m) {
                auto reprBuilder = appender!(string[]);
                reprBuilder.reserve(m.length);

                foreach (pair; m.values()) {
                    reprBuilder.put(format("%s: %s", pair.key, pair.value));
                }

                const auto blockRepr = reprBuilder[].joiner(",").to!string;
                return (blockRepr != "") ? format("{%s}", blockRepr) : "{}";
            }, (Quote value) => format("%s",
                    value.node.match!(node => node.show(this.parser.lexer))),
                    (ErrorValue result) => result.message, (ReturnValue result) {
                return (*result).match!((Unit _) => "", (ErrorValue result) => result.message,
                    (Character c) => format("'%c'", c.value),
                    (long value) => format("%d", value), (value) => format("%s", value));
            }, (Function _) => "<Function>", (Macro _) => "<Macro>", (Unit _) => "",
                    (result) => format("%s", result));
        }
    }
}

/// Helper function to parse program before evaluating its statements/expressions
private Evaluator* prepareEvaluator(const string input)
{
    import lexer : Lexer;

    auto lexer = Lexer(input);
    lexer.tokenize();

    auto parser = Parser(lexer);
    parser.parseProgram();

    auto env = new Environment();
    auto macroEnv = new Environment();
    auto evaluator = new Evaluator(parser, env, macroEnv);

    evaluator.defineMacros();
    evaluator.expandMacros();

    return evaluator;
}

/// Basic integer test
unittest {
    const auto input = "5; 10;
-5; -10";
    const long[4] expected = [5, 10, -5, -10];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((long value) => assert(value == expected[i],
                format("Number value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected int value in statement %s", i)));
    }
}

/// More complex integer test
unittest {
    const auto input = "5; 10; -5; -10;
5 + 5 + 5 + 5 - 10;
2 * 2 * 2 * 2 * 2;
-50 + 100 + -50;
5 * 2 + 10;
5 + 2 * 10;
20 + 2 * -10;
50 / 2 * 2 + 10;
2 * (5 + 10);
3 * 3 * 3 + 10;
3 * (3 * 3) + 10;
(5 + 10 * 2 + 15 / 3) * 2 + -10;";

    const long[15] expected = [
        5, 10, -5, -10, 10, 32, 0, 20, 25, 0, 60, 30, 37, 37, 50
    ];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((long value) => assert(value == expected[i],
                format("Number value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected int value in statement %s", i)));
    }
}

/// Basic string test
unittest {
    const auto input = "\"Hi\"; \"There\";
\"foo\"; \"bar\"";

    const string[4] expected = ["Hi", "There", "foo", "bar"];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((string value) => assert(value == expected[i],
                format("String value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected string value in statement %s", i)));
    }
}

/// String append test
unittest {
    const auto input = "\"Thorsten\" + \" \" + \"Ball\";";
    const string[1] expected = ["Thorsten Ball"];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((string value) => assert(value == expected[i],
                format("String value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected string value in statement %s", i)));
    }
}

/// Basic array test
unittest {
    const auto input = "[1, 2 * 2, 3 + 3]";
    const long[3] expected = [1, 4, 6];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    evaluator.results[][0].match!((long _) => assert(false,
            "Expected array value in statement"), (Results arr) {
        foreach (i, value; arr.enumerate(0)) {
            value.match!((long v) {
                assert(v == expected[i],
                format("Int value %s does not match expected value %s", v, expected[i]));
            }, _ => assert(false, format("Expected int value in array index %d", i)));
        }
    }, _ => assert(false, "Expected array value in statement"));
}

/// Array and string len test
unittest {
    const auto input = "len([1, 2 * 2, 3 + 3]);
    len([]); len(\"1234\"); len(\"Hello world!\");";
    const long[4] expected = [3, 0, 4, 12];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((long value) => assert(value == expected[i],
                format("Number value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected int value in statement %s", i)));
    }
}

/// Array index test
unittest {
    const auto input = "[1, 2, 3][0]";
    const long expected = 1;

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((long value) {
            assert(value == expected,
                format("Int value %s does not match expected value %s", value, expected));
        }, _ => assert(false, format("Expected array value in statement %s", i)));
    }
}

/// Hashmap index test
unittest {
    const auto input = "let people = [{\"name\": \"Alice\", \"age\": 24}, {\"name\": \"Anna\", \"age\": 28}];
people[1][\"age\"];
people[0][\"name\"];
";
    const long expectedInt = 28;
    const string expectedString = "Alice";

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    evaluator.results[][1].match!((long value) {
        assert(value == expectedInt,
            format("Int value %s does not match expected value %s", value, expectedInt));
    }, _ => assert(false, "Expected int value in map statement"));

    evaluator.results[][2].match!((string value) {
        assert(value == expectedString,
            format("String value %s does not match expected value %s", value, expectedString));
    }, _ => assert(false, "Expected string value in map statement"));
}

/// Builtin function test
unittest {
    const auto input = "len([9,8,7]);
    first([9,8,7]);
    last([9,8,7]);";
    const long[3] expected = [3, 9, 7];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((long value) {
            assert(value == expected[i],
                format("Int value %s does not match expected value %s", value, expected[i]));
        }, _ => assert(false, format("Expected number in statement %s", i)));
    }
}

/// Quote function test
unittest {
    const auto input = "quote(foobar);
quote(10 + 5);
quote(foobar + 10 + 5 + barfoo);
quote(unquote(quote(4 + 4)));
quote(unquote(4 + 4) + unquote(quote(4 + 4)));";

    const string[5] expected = [
        "foobar", "(10 + 5)", "(((foobar + 10) + 5) + barfoo)", "(4 + 4)",
        "(8 + (4 + 4))"
    ];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((Quote value) {
            auto quotedValue = value.node.match!(node => node.show(evaluator.parser.lexer));

            assert(quotedValue == expected[i],
                format("Quoted node %s does not match expected value %s", quotedValue, expected[i]));
        }, _ => assert(false, format("Expected number in statement %d", i)));
    }
}

/// Basic hashmap test
unittest {
    const auto input = "let people = [{\"name\": \"Alice\", \"age\": 24}, {\"name\": \"Anna\", \"age\": 28}];
people[1][\"age\"] + people[0][\"age\"];";
    const long expected = 52;

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    evaluator.results[][1].match!((long value) {
        assert(value == expected,
            format("Int value %d does not match expected value %d", value, expected));
    }, _ => assert(false, "Expected number in statement 1"));
}

/// Builtin rest function base test
unittest {
    const auto input = "rest([9,8,7]);";
    const long[2] expected = [8, 7];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    evaluator.results[][0].match!((Results arr) {
        foreach (i, result; arr.enumerate(0)) {
            result.match!((long value) {
                assert(value == expected[i],
                format("Int value %s does not match expected value %s", value, expected[i]));
            }, _ => assert(false, format("Expected int in array value %d", i)));
        }
    }, _ => assert(false, "Expected array value"));
}

/// Builtin rest function empty test
unittest {
    const auto input = "rest([3]);";
    const long[0] expected = [];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((Results value) {
            assert(value.empty, "Int values expected to be empty");
        }, _ => assert(false, format("Expected array in statement %s", i)));
    }
}

/// Basic boolean test
unittest {
    const auto input = "true; false;
!true; !false;
!5; !!true; !!false; !!5;
";

    const bool[8] expected = [
        true, false, false, true, false, true, false, true
    ];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((bool value) => assert(value == expected[i],
                format("Bool value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected bool value in statement %s", i)));
    }
}

/// Complex boolean test
unittest {
    const auto input = "true; false;
1 < 2; 1 > 2;
1 < 1; 1 > 1;
1 == 1;
1 != 1;
1 == 2;
1 != 2;
";

    const bool[10] expected = [
        true, false, true, false, false, false, true, false, false, true
    ];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((bool value) => assert(value == expected[i],
                format("Bool value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected bool value in statement %s", i)));
    }
}

/// Boolean evaluations test
unittest {
    const auto input = "true == true;
false == false;
true == false;
true != false;
false != true;
(1 < 2) == true; (1 < 2) == false;
(1 > 2) == true; (1 > 2) == false;
";

    const bool[9] expected = [
        true, true, false, true, true, true, false, false, true
    ];

    auto evaluator = prepareEvaluator(input);
    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((bool value) => assert(value == expected[i],
                format("Bool value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Expected bool value in statement %s", i)));
    }
}

/// Compound expression statement test
unittest {
    const auto input = "3 < 5 == false;
3 > 5 == false;
1 + (2 + 3) + 4;
(5 + 5) * 2;
2 / (5 + 5);
-(5 + 5);
!(true == true);";

    const long[7] expected = [false, true, 10, 20, 0, -10, false];
    auto evaluator = prepareEvaluator(input);

    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((bool value) => assert(value == expected[i],
                format("Bool value %s does not match expected value %s", value, expected[i])),
                (long value) => assert(value == expected[i],
                    format("Number value %s does not match expected value %s", value, expected[i])),
                _ => assert(false, format("Unhandled type in statement %d", i)));
    }
}

/// If else expression statement test
unittest {
    const auto input = "if (true) { 10 }
if (false) { 10 }
if (1) { 10 }
if (1 < 2) { 10 }
if (1 > 2) { 10 }
if (1 > 2) { 10 } else { 20 }
if (1 < 2) { 10 } else { 20 }
if (5 * 5 + 10 > 34) { 99 } else { 100 }
if ((1000 / 2) + 250 * 2 == 1000) { 9999 }";

    const long[9] expected = [10, 0, 10, 10, 0, 20, 10, 99, 9999];
    auto evaluator = prepareEvaluator(input);

    evaluator.evalProgram();

    foreach (i, result; evaluator.results[]) {
        result.match!((bool value) => assert(value == expected[i],
                format("Bool value %s does not match expected value %s", value, expected[i])),
                (long value) => assert(value == expected[i],
                    format("Number value %s does not match expected value %s", value, expected[i])),
                (Unit _) => assert(true,
                    "Solar flare detected"),
                _ => assert(false, format("Unhandled type in statement %d", i)));
    }
}

/// Return statement test
unittest {
    const string[4] inputs = [
        "return 10;", "return 10; 9;", "return 2 * 5; 9;", "9; return 10; 9;"
    ];

    const int[4] expected = [10, 10, 10, 10];

    for (int i = 0; i < inputs.length; i++) {
        auto evaluator = prepareEvaluator(inputs[i]);

        evaluator.evalProgram();

        auto result = evaluator.results[][$ - 1];

        result.match!((ReturnValue value) {
            return (*value).match!((long lValue) => assert(lValue == expected[i],
                format("Number value %s does not match expected value %d", lValue, expected[i])),
                _ => assert(false, format("Unhandled type in program %d", i)));
        }, _ => assert(false, format("Unhandled type in program %d", i)));
    }
}

/// Error handling statement test
unittest {
    const string[8] inputs = [
        "5 + true;", "5 + true; 5;", "-true", "true + false", "5; true + false; 5",
        "if (10 > 1) { true + false; }",
        "if (10 > 1) { if (10 > 1) { return true + false; } return 1; }", "foobar"
    ];

    const string[8] expected = [
        "Type mismatch in expression: INTEGER + BOOLEAN",
        "Type mismatch in expression: INTEGER + BOOLEAN",
        "Unknown operator: -BOOLEAN", "Unknown operator: BOOLEAN + BOOLEAN",
        "Unknown operator: BOOLEAN + BOOLEAN",
        "Unknown operator: BOOLEAN + BOOLEAN",
        "Unknown operator: BOOLEAN + BOOLEAN", "Unknown symbol: foobar"
    ];

    for (int i = 0; i < inputs.length; i++) {
        auto evaluator = prepareEvaluator(inputs[i]);

        evaluator.evalProgram();

        auto result = evaluator.results[][$ - 1];

        result.match!((ErrorValue value) {
            assert(value.message == expected[i],
                format("Error message %s does not match expected message %d",
                value.message, expected[i]));
        }, _ => assert(false, format("Unhandled type in program %d", i)));
    }
}

/// Let statement test
unittest {
    const string[4] inputs = [
        "let a = 5; a;", "let a = 5 * 5; a;", "let a = 5; let b = a; b;",
        "let a = 5; let b = a; let c = a + b + 5; c;"
    ];

    const long[4] expected = [5, 25, 5, 15];

    for (int i = 0; i < inputs.length; i++) {
        auto evaluator = prepareEvaluator(inputs[i]);

        evaluator.evalProgram();

        auto result = evaluator.results[][$ - 1];

        result.match!((long value) {
            assert(value == expected[i],
                format("Number value %s does not match expected value %d", value, expected[i]));
        }, _ => assert(false, format("Unhandled type in program %d", i)));
    }
}

/// Function statement test
unittest {
    const string[6] inputs = [
        "let identity = fn(x) { x; }; identity(5);",
        "let identity = fn(x) { return x; }; identity(5);",
        "let double = fn(x) { x * 2; }; double(5);",
        "let add = fn(x, y) { x + y; }; add(5, 5);",
        "let add = fn(x, y) { x + y; }; add(5 + 5, add(5, 5));", "fn(x) { x; }(5)"
    ];

    const long[6] expected = [5, 5, 10, 10, 20, 5];

    for (int i = 0; i < inputs.length; i++) {
        auto evaluator = prepareEvaluator(inputs[i]);

        evaluator.evalProgram();

        auto result = evaluator.results[][$ - 1];

        result.match!((ReturnValue rValue) {
            return (*rValue).match!((long value) {
                assert(value == expected[i],
                format("Number value %s does not match expected value %d", value, expected[i]));
            }, _ => assert(false, format("Unhandled type in program %d", i)));
        }, (long value) {
            assert(value == expected[i],
                format("Number value %s does not match expected value %d", value, expected[i]));
        }, _ => assert(false, format("Unhandled type in program %d :: %s", i, result)));
    }
}

/// Basic closure test
unittest {
    const string input = "let newAdder = fn(x) {
fn(y) { x + y };
};

let addTwo = newAdder(2); addTwo(2);
";

    const long expected = 4;

    auto evaluator = prepareEvaluator(input);

    evaluator.evalProgram();

    auto result = evaluator.results[][$ - 1];

    result.match!((long value) {
        assert(value == expected,
            format("Number value %s does not match expected value %d", value, expected));
    }, _ => assert(false, "Unhandled type in program"));
}

/// Counter closure test
unittest {
    const string input = "let counter = fn(x) {
  if (x > 100) {
    return true;
  } else {
    let foobar = 9999;
    counter(x + 1);
  }
};

counter(0);
";

    const bool expected = true;

    auto evaluator = prepareEvaluator(input);

    evaluator.evalProgram();

    auto result = evaluator.results[][$ - 1];

    result.match!((ReturnValue rValue) {
        return (*rValue).match!((bool value) {
            assert(value == expected,
            format("Bool value %s does not match expected value %s", value, expected));
        }, _ => assert(false, "Unhandled type in program"));
    }, _ => assert(false, "Unhandled type in program"));
}

/// Basic macro test
unittest {
    const string input = "let unless = macro(condition, consequence, alternative) {
      quote(if (!(unquote(condition))) {
          unquote(consequence);
          } else {
          unquote(alternative);
          });
    };

unless(10 > 5, \"nope, not greater\", \"yep, greater\");
";

    const string expected = "yep, greater";

    auto evaluator = prepareEvaluator(input);

    evaluator.evalProgram();

    auto result = evaluator.results[][$ - 1];

    result.match!((string value) {
        assert(value == expected,
            format("string value %s does not match expected value %d", value, expected));
    }, _ => assert(false, "Unhandled type in program"));
}
