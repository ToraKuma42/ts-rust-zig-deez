/**
 * Expression structures based on the awesome book
 * "Writing an Interpreter in Go" by Thorsten Ball.
 *
 * Authors: ToraKuma42
 * License: MIT
 * Version: 0.0.1
 */

import atom;
import hashable;
import lexer;
import parser;
import quote;

import openmethods;

mixin(registerMethods);

import std.array : appender, Appender;
import std.bitmanip : peek;
import std.conv : to;
import std.format : format;
import std.range : empty;
import std.stdio : writefln;
import std.sumtype : match;
import std.typecons : Tuple;

/// Rep of operators for expressions
/// Duplicated from Lexer, but we need to only index tag enum, not special
private const string[TokenTag.Return + 1] OPS_TAG = [
    TokenTag.Eq: "==", TokenTag.NotEq: "!=", TokenTag.Assign: "=",
    TokenTag.Plus: "+", TokenTag.Minus: "-", TokenTag.Bang: "!",
    TokenTag.Asterisk: "*", TokenTag.Slash: "/", TokenTag.Lt: "<",
    TokenTag.Gt: ">", TokenTag.Comma: ":", TokenTag.Semicolon: ";"
];

/// Builtin functions
private alias evalResult(T) = mixin("(", T, " value) => EvalResult(value)");

/// Measure length of array or string
EvalResult len(EvalResult[] vars...)
{
    if (vars.length != 1) {
        return EvalResult(ErrorValue(format("Wrong number of arguments. Got %d arguments, want 1 argument",
                vars.length)));
    }

    alias arrLen(T) = mixin("(", T, " value) => EvalResult(value.length)");

    return vars[0].match!((Results value) => EvalResult(value.length), arrLen!(string),
            _ => EvalResult(ErrorValue("`len` not supported for argument")));
}

/// First element of array
EvalResult first(EvalResult[] vars...)
{
    if (vars.length != 1) {
        return EvalResult(ErrorValue(format("Wrong number of arguments. Got %d arguments, want 1 argument",
                vars.length)));
    }

    return vars[0].match!((Results arr) => (arr.length > 0) ? arr[0] : NIL_ATOM, (string str) {
        if (str.length > 0) {
            return EvalResult(Character(str[0]));
        } else {
            return EvalResult(Character('\0'));
        }
    }, _ => EvalResult(ErrorValue("`first` not supported for argument")));
}

/// Last element of array
EvalResult last(EvalResult[] vars...)
{
    if (vars.length != 1) {
        return EvalResult(ErrorValue(format("Wrong number of arguments. Got %d arguments, want 1 argument",
                vars.length)));
    }

    return vars[0].match!((Results arr) => (arr.length > 0) ? arr[$ - 1] : NIL_ATOM, (string str) {
        if (str.length > 0) {
            return EvalResult(Character(str[$ - 1]));
        } else {
            return EvalResult(Character('\0'));
        }
    }, _ => EvalResult(ErrorValue("`last` not supported for argument")));
}

/// View of array tail
EvalResult rest(EvalResult[] vars...)
{
    if (vars.length != 1) {
        return EvalResult(ErrorValue(format("Wrong number of arguments. Got %d arguments, want 1 argument",
                vars.length)));
    }

    return vars[0].match!((Results arr) {
        if (arr.length > 1) {
            return EvalResult(arr[1 .. $]);
        } else {
            return EMPTY_ARRAY_ATOM;
        }
    }, (string str) {
        if (str.length > 1) {
            return EvalResult(str[1 .. $]);
        } else {
            return EvalResult(Character('\0'));
        }
    }, _ => EvalResult(ErrorValue("`rest` not supported for argument")));
}

/// Append single value to array tail
EvalResult push(EvalResult[] vars...)
{
    if (vars.length != 2) {
        return EvalResult(ErrorValue(format("Wrong number of arguments. Got %d arguments, want 2 arguments",
                vars.length)));
    }

    return vars[0].match!((Results arr) => EvalResult(arr ~ vars[1]),
            _ => EvalResult(ErrorValue("argument to `push` must be array")));
}

/// Print variable in stdout
EvalResult puts(EvalResult[] vars...)
{
    alias printValue(T) = mixin("(", T, " value) => writefln(\"%s\", value)");
    alias printNumber(T) = mixin("(", T, " value) => writefln(\"%d\", value)");

    // Write repr of each entry in vararg
    foreach (var; vars) {
        var.match!((Results arr) => writefln("%s", arr), printValue!(bool),
                printNumber!(long), printValue!(string), printValue!(void*), (_) {
        });
    }

    // End with unit effect
    return NIL_ATOM;
}

immutable BuiltinFunction[string] builtinFunctions; /// Map keywords to builtin functions

shared static this()
{
    import std.exception : assumeUnique;

    BuiltinFunction[string] tempBuiltinFunctions = [
        "quote": null  /* handled by another function */ , "puts": &puts,
        "len": &len, "first": &first, "last": &last, "rest": &rest, "push": &push,
    ];

    builtinFunctions = assumeUnique(tempBuiltinFunctions);
}

/**
 * Translate any expression node to result value
 * Params:
 * node = The expression node to evaluate
 * lexer = The lexer for showing node values
 * env = The environment storing variables
 * Returns: The final evaluation result
 */
EvalResult eval(virtual!ExpressionNode node, ref Lexer lexer, Environment* env);

/// Simple translation of node into boolean value
@method EvalResult _eval(BooleanNode node, ref Lexer lexer, Environment* _)
{
    return EvalResult(to!bool(node.show(lexer)));
}

/// Simple translation of node into string value
@method EvalResult _eval(StringNode node, ref Lexer lexer, Environment* _)
{
    return EvalResult(node.show(lexer));
}

/// Simple translation of node into integer value
@method EvalResult _eval(IntNode node, ref Lexer lexer, Environment* _)
{
    return EvalResult(to!long(node.show(lexer)));
}

/// Search for identifier in environment before returning its value
@method EvalResult _eval(IdentifierNode node, ref Lexer lexer, Environment* env)
{
    const string name = node.show(lexer);

    for (Environment* localEnv = env; localEnv !is null; localEnv = localEnv.outer) {
        if (name in localEnv.items) {
            return localEnv.items[name];
        } else if (name in builtinFunctions) {
            return EvalResult(BuiltinFunctionKey(name));
        }
    }

    return EvalResult(ErrorValue(format("Unknown symbol: %s", name)));
}

/// Prefix expression handlers
private EvalResult boolPrefix(PrefixExpressionNode node, bool value)
{
    if ((node.op) == TokenTag.Bang) {
        return (!value) ? TRUE_ATOM : FALSE_ATOM;
    } else {
        return EvalResult(ErrorValue(format("Unknown operator: %sBOOLEAN", OPS_TAG[node.op])));
    }
}

private EvalResult longPrefix(PrefixExpressionNode node, long value)
{
    switch (node.op) with (TokenTag) {
        static foreach (op; [Minus, Bang]) {
    case op:
            return mixin("EvalResult(", OPS_TAG[op], "value)");
        }
    default:
        assert(0);
    }
}

/// Evaluate prefix expression
@method EvalResult _eval(PrefixExpressionNode node, ref Lexer lexer, Environment* env)
{
    EvalResult result = eval(node.expr, lexer, env);

    return result.match!((bool value) => boolPrefix(node, value),
            (long value) => longPrefix(node, value), (string _) => EvalResult(
                "String not supported in prefix expression"), (ReturnValue prefixValue) {
        return (*prefixValue).match!((bool value) => boolPrefix(node, value),
            (long value) => longPrefix(node, value),
            (string _) => EvalResult("String not supported in prefix expression"),
            _ => EvalResult(ErrorValue("Unsupported type in LHS of infix expression")));
    }, (ErrorValue err) => EvalResult(err), _ => UNIT_ATOM);
}

/// Infix expression handlers
private EvalResult boolInfix(InfixExpressionNode node, bool lValue, EvalResult right)
{
    return right.match!((bool rValue) {
        switch (node.op) with (TokenTag) {
            static foreach (op; [Eq, NotEq, Gt, Lt]) {
        case op:
                return mixin("(lValue", OPS_TAG[op], "rValue) ? TRUE_ATOM : FALSE_ATOM");
            }
        default:
            return EvalResult(ErrorValue(format("Unknown operator: BOOLEAN %s BOOLEAN",
                OPS_TAG[node.op])));
        }
    }, (long _) => EvalResult(ErrorValue(format("Type mismatch in expression: BOOLEAN %s INTEGER", OPS_TAG[node.op]))),
            _ => EvalResult(ErrorValue("Type in RHS of expression does not match BOOLEAN")));
}

private EvalResult longInfix(InfixExpressionNode node, long lValue, EvalResult right)
{
    return right.match!((bool _) => EvalResult(ErrorValue(format("Type mismatch in expression: INTEGER %s BOOLEAN",
            OPS_TAG[node.op]))), (long rValue) {
        switch (node.op) with (TokenTag) {
            static foreach (op; [Eq, NotEq, Gt, Lt]) {
        case op:
                return mixin("(lValue", OPS_TAG[op], "rValue) ? TRUE_ATOM : FALSE_ATOM");
            }
            static foreach (op; [Plus, Minus, Asterisk, Slash]) {
        case op:
                return mixin("EvalResult(lValue", OPS_TAG[op], "rValue)");
            }
        default:
            return EvalResult(ErrorValue(format("Unknown operator: INTEGER %s INTEGER",
                OPS_TAG[node.op])));
        }
    }, _ => EvalResult(ErrorValue("Type in RHS of expression does not match INTEGER")));
}

private EvalResult stringInfix(InfixExpressionNode node, string lValue, EvalResult right)
{
    return right.match!((string rValue) {
        if (node.op == TokenTag.Plus) {
            return EvalResult(lValue ~ rValue);
        } else {
            return EvalResult(ErrorValue(format("Unknown operator: STRING %s STRING",
                OPS_TAG[node.op])));
        }
    }, (bool _) => EvalResult(ErrorValue(format("Type mismatch in expression: STRING %s BOOLEAN",
            OPS_TAG[node.op]))), (long _) => EvalResult(ErrorValue(format(
            "Type mismatch in expression: STRING %s INTEGER", OPS_TAG[node.op]))),
            _ => EvalResult(ErrorValue("Type in RHS of expression does not match STRING")));
}

/// Evaluate infix expression
@method EvalResult _eval(InfixExpressionNode node, ref Lexer lexer, Environment* env)
{
    const EvalResult left = eval(node.lhs, lexer, env);
    const EvalResult right = eval(node.rhs, lexer, env);

    return left.match!((bool lValue) => boolInfix(node, lValue, right),
            (long lValue) => longInfix(node, lValue, right),
            (string lValue) => stringInfix(node, lValue, right), (const ReturnValue lhsValue) {
        return (*lhsValue).match!((bool lValue) => boolInfix(node, lValue,
            right), (long lValue) => longInfix(node, lValue, right),
            (string lValue) => stringInfix(node, lValue, right),
            _ => EvalResult(ErrorValue("Unsupported type in LHS of infix expression")));
    }, (ErrorValue err) => EvalResult(err), _ => UNIT_ATOM);
}

/// Evaluate if-then-else expression
@method EvalResult _eval(IfExpressionNode node, ref Lexer lexer, Environment* env)
{
    // Check value of expression
    const EvalResult result = eval(node.expr, lexer, env);

    bool truthy = result.match!((bool value) => value, (long value) => value
            ? true : false, (string _) => true, (const ReturnValue value) {
        return (*value).match!((bool wrappedValue) => wrappedValue,
            (long wrappedValue) => wrappedValue ? true : false, (string _) => true, _ => false);
    }, _ => false);

    // if expr value true ? evaluate true branch : false branch
    if (truthy) {
        return evalStatement(node.trueBranch, lexer, env); /// Consequence expression
    } else if (node.falseBranch !is null) {
        return evalStatement(node.falseBranch, lexer, env); /// Alternative expression
    } else {
        return UNIT_ATOM;
    }
}

/// Generate function literal from node
@method EvalResult _eval(FunctionLiteralNode node, ref Lexer lexer, Environment* env)
{
    return EvalResult(Function(&node.parameters, &node.functionBody, env));
}

/// Generate macro literal from node
@method EvalResult _eval(MacroLiteralNode node, ref Lexer lexer, Environment* env)
{
    return EvalResult(Macro(&node.parameters, &node.macroBody, env));
}

/// Evaluate array literal
@method EvalResult _eval(ArrayLiteralNode node, ref Lexer lexer, Environment* env)
{
    auto elements = evalExpressions(node.elements, lexer, env);

    if (elements.length == 1) {
        const auto value = elements[0];
        if (value.match!((ErrorValue _) => true, _ => false)) {
            return value;
        }
    }

    return EvalResult(elements);
}

/// Evaluate hashmap literal
@method EvalResult _eval(HashLiteralNode node, ref Lexer lexer, Environment* env)
{
    ResultMap pairsResult;

    foreach (keyNode, valueNode; node.pairs) {
        auto key = eval(keyNode, lexer, env);

        if (key.match!((ErrorValue _) => true, _ => false)) {
            return key;
        }

        if (key.match!((bool _) => false, (long _) => false, (string _) => false, _ => true)) {
            return EvalResult(ErrorValue("Unusable hash key"));
        }

        auto value = eval(valueNode, lexer, env);

        if (value.match!((ErrorValue _) => true, _ => false)) {
            return value;
        }

        auto hashedKey = key.match!((bool value) => HashKey(value ? 1 : 0,
                HashType.Boolean), (long value) => HashKey(value, HashType.Int),
                (string value) => hashGen(value), _ => assert(false, "Unreachable statement"));

        pairsResult[hashedKey] = HashPair(key, value);
    }

    return EvalResult(pairsResult);
}

/// Array/Hashmap index expression handlers
private EvalResult longIndex(IndexExpressionNode node, EvalResult lhs, long idx)
{
    return lhs.match!((Results left) {
        if (idx < 0 || idx >= left.length) {
            return NIL_ATOM;
        }

        return left[idx];
    }, (ResultMap left) {
        auto key = HashKey(idx, HashType.Int);
        if (key !in left) {
            return NIL_ATOM;
        }

        return left[key].value;
    }, _ => EvalResult(ErrorValue("Index operator not supported for non-array/map on LHS")));
}

private EvalResult stringIndex(IndexExpressionNode node, EvalResult lhs, string idx)
{
    return lhs.match!((ResultMap left) {
        if (idx is null || idx.empty) {
            return NIL_ATOM;
        }

        auto key = hashGen(idx);
        if (key !in left) {
            return NIL_ATOM;
        }

        return left[key].value;
    }, _ => EvalResult(ErrorValue("Index operator not supported for non-map on LHS")));
}

private EvalResult boolIndex(IndexExpressionNode node, EvalResult lhs, bool idx)
{
    return lhs.match!((ResultMap left) {
        auto key = HashKey(idx ? 1 : 0, HashType.Boolean);
        if (key !in left) {
            return NIL_ATOM;
        }

        return left[key].value;
    }, _ => EvalResult(ErrorValue("Index operator not supported for non-map on LHS")));
}

/// Evaluate array index expression
@method EvalResult _eval(IndexExpressionNode node, ref Lexer lexer, Environment* env)
{
    auto lhs = eval(node.lhs, lexer, env);
    if (lhs.match!((ErrorValue _) => true, _ => false)) {
        return lhs;
    }

    auto index = eval(node.index, lexer, env);

    return index.match!((bool idx) => boolIndex(node, lhs, idx),
            (string idx) => stringIndex(node, lhs, idx), (long idx) => longIndex(node,
                lhs, idx), (ErrorValue _) => index, (ReturnValue value) {
        return (*value).match!((bool idx) => boolIndex(node, lhs, idx),
            (string idx) => stringIndex(node, lhs, idx), (long idx) => longIndex(node, lhs, idx),
            _ => EvalResult(ErrorValue("Index operator not supported on RHS")));
    }, _ => EvalResult(ErrorValue("Index operator not supported on RHS")));
}

/// Helper functions for evaluating unquote calls
NodeADT convertObjectToASTNode(EvalResult result)
{
    return result.match!((bool value) => NodeADT(new BooleanResultNode(value)),
            (long value) => NodeADT(new IntResultNode(value)),
            (string value) => NodeADT(new StringResultNode(value)), (Quote value) => value.node,
            _ => assert(false, "Unreachable object to convert into AST node"));
}

NodeADT modifyAndEvalUnquote(ref Lexer lexer, Environment* env, NodeADT node)
{
    return node.match!((CallExpressionNode callNode) {
        if (callNode.functionBody.show(lexer) != "unquote" || callNode.args.length != 1) {
            return node;
        }

        auto unquoted = eval(callNode.args[0], lexer, env);
        return convertObjectToASTNode(unquoted);
    }, exprNode => node);
}

NodeADT modifyAndExpandMacro(ref Lexer lexer, Environment* env, NodeADT node)
{
    return node.match!((CallExpressionNode callNode) {
        // check if call node is macro
        auto id = cast(IdentifierNode)(callNode.functionBody);
        if (id is null) {
            return node;
        }

        const auto key = lexer.tagRepr(id.mainIdx);
        if (key !in env.items) {
            return node;
        }

        return env.items[key].match!((Macro macroLiteral) {
            // quote arguments and extend macro environment
            auto args = appender!(Quote[])();
            foreach (arg; callNode.args) {
                args.put(Quote(NodeADT(arg)));
            }

            auto extendedEnv = extendMacroEnv(macroLiteral, args[], lexer);

            // evaluate macro body based on extended env
            auto evaluated = evalStatement(*(macroLiteral.macroBody), lexer, extendedEnv);

            // check if eval'd result is quote; otherwise, panic
            return evaluated.match!((Quote quote) => quote.node, _ => assert(false,
            "We only support returning AST nodes from macros"));
        }, _ => node);
    }, exprNode => node);
}

/// Evaluate function call
@method EvalResult _eval(CallExpressionNode node, ref Lexer lexer, Environment* env)
{
    auto exprValue = eval(node.functionBody, lexer, env);

    return exprValue.match!((BuiltinFunctionKey key) {
        if (key.name == "quote") {
            auto newNode = modify(node.args[0], lexer, env, &modifyAndEvalUnquote);
            return EvalResult(Quote(newNode));
        }

        auto args = evalExpressions(node.args, lexer, env);

        if (args.length == 1) {
            const auto value = args[0];
            if (value.match!((ErrorValue _) => true, _ => false)) {
                return value;
            }
        }

        return builtinFunctions[key.name](args);
    }, (Function literal) {
        auto args = evalExpressions(node.args, lexer, env);

        if (args.length == 1) {
            const auto value = args[0];
            if (value.match!((ErrorValue _) => true, _ => false)) {
                return value;
            }
        }

        return applyFunction(literal, args, lexer);
    }, (ErrorValue error) => EvalResult(error), value => EvalResult(value));
}

/// Evaluate function with an extended environment
EvalResult applyFunction(Function literal, EvalResult[] args, ref Lexer lexer)
{
    auto extendedEnv = extendFunctionEnv(literal, args, lexer);
    return evalStatement(*literal.functionBody, lexer, extendedEnv);
}

/// Evaluate all expressions in param listing until either error or completion
EvalResult[] evalExpressions(ExpressionNode[] exprs, ref Lexer lexer, Environment* env)
{
    auto results = appender!(EvalResult[])();
    results.reserve(exprs.length);

    // Evaluate expressions until we hit error
    foreach (expression; exprs) {
        auto result = eval(expression, lexer, env);
        if (result.match!((ErrorValue _) => true, _ => false)) {
            return [result];
        }

        results.put(result);
    }

    return results[];
}

/**
 * Translate any statement to result value
 * Params:
 * node = The statement node to evaluate
 * lexer = The lexer for showing node values
 * env = The environment storing variables
 * Returns: The final evaluation result
 */
EvalResult evalStatement(virtual!StatementNode node, ref Lexer lexer, Environment* env);

/// Evaluate expression wrapped inside statement node
@method EvalResult _evalStatement(ExpressionStatement node, ref Lexer lexer, Environment* env)
{
    return eval(node.expr, lexer, env);
}

/// Declare new variable either globally or inside block
@method EvalResult _evalStatement(LetStatement node, ref Lexer lexer, Environment* env)
{
    const auto exprValue = eval(node.expr, lexer, env);

    return exprValue.match!((ErrorValue error) => EvalResult(error), (_) {
        const auto id = lexer.tagRepr(node.mainIdx);

        if (id in env.items) {
            // TODO: allow shadowing on interpreter extension?
            return EvalResult(ErrorValue(format("Symbol already defined: %s", id)));
        } else {
            env.items[id] = exprValue;
            return UNIT_ATOM;
        }
    });
}

/// Return value from evaluated expression inside statement
@method EvalResult _evalStatement(ReturnStatement node, ref Lexer lexer, Environment* env)
{
    if (node.expr !is null) {
        EvalResult result = eval(node.expr, lexer, env);

        return result.match!((bool value) => EvalResult(value ? TRUE_RETURN_ATOM
                : FALSE_RETURN_ATOM), (long value) => EvalResult(new EvalResult(value)),
                (string value) => EvalResult(new EvalResult(value)), (ErrorValue _) => result,
                (Results arr) => EvalResult(new EvalResult(arr)),
                (ReturnValue _) => result, _ => EvalResult(VOID_RETURN_ATOM));
    } else {
        return EvalResult(VOID_RETURN_ATOM);
    }
}

/// Evaluate all statements in block until return or completion
@method EvalResult _evalStatement(BlockStatement node, ref Lexer lexer, Environment* env)
{
    EvalResult value = EvalResult(VOID_RETURN_ATOM);
    bool notReturn = true;

    for (auto i = 0; (i < node.statements.length) && notReturn; i++) {
        value = evalStatement(node.statements[i], lexer, env);
        notReturn = value.match!((ReturnValue _) => false, (ErrorValue _) => false, _ => true);
    }

    return value;
}
