#!/usr/bin/env python3
"""Example MCP server: exact arithmetic and unit conversion."""
import ast
import math
import operator
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_minimal import NUMBER, TEXT, obj, serve

OPS = {
    ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
    ast.Div: operator.truediv, ast.Pow: operator.pow, ast.Mod: operator.mod,
    ast.FloorDiv: operator.floordiv, ast.USub: operator.neg, ast.UAdd: operator.pos,
}
NAMES = {"pi": math.pi, "e": math.e}
FUNCS = {"sqrt": math.sqrt, "sin": math.sin, "cos": math.cos, "tan": math.tan, "log": math.log,
         "log10": math.log10, "abs": abs, "round": round, "floor": math.floor, "ceil": math.ceil}


def evaluate(node):
    if isinstance(node, ast.Expression):
        return evaluate(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in OPS:
        left, right = evaluate(node.left), evaluate(node.right)
        if isinstance(node.op, ast.Pow) and abs(right) > 1000:
            raise ValueError("exponent too large")
        return OPS[type(node.op)](left, right)
    if isinstance(node, ast.UnaryOp) and type(node.op) in OPS:
        return OPS[type(node.op)](evaluate(node.operand))
    if isinstance(node, ast.Name) and node.id in NAMES:
        return NAMES[node.id]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in FUNCS and not node.keywords:
        return FUNCS[node.func.id](*[evaluate(arg) for arg in node.args])
    raise ValueError("only numbers, + - * / ** % //, pi, e and sqrt/sin/cos/tan/log/log10/abs/round/floor/ceil are allowed")


def calculate(args):
    expression = args.get("expression", "")
    if not isinstance(expression, str) or len(expression) > 300:
        raise ValueError("give an expression of at most 300 characters")
    return "%s = %s" % (expression, evaluate(ast.parse(expression, mode="eval")))


LENGTH = {"m": 1.0, "km": 1000.0, "cm": 0.01, "mm": 0.001, "in": 0.0254, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344}
MASS = {"kg": 1.0, "g": 0.001, "lb": 0.45359237, "oz": 0.028349523125}


def convert(args):
    value, source, target = float(args["value"]), args["from"], args["to"]
    for table in (LENGTH, MASS):
        if source in table and target in table:
            return "%g %s = %g %s" % (value, source, value * table[source] / table[target], target)
    temps = {"c": lambda v: v, "f": lambda v: (v - 32) * 5 / 9, "k": lambda v: v - 273.15}
    back = {"c": lambda v: v, "f": lambda v: v * 9 / 5 + 32, "k": lambda v: v + 273.15}
    if source.lower() in temps and target.lower() in back:
        return "%g %s = %g %s" % (value, source, back[target.lower()](temps[source.lower()](value)), target)
    raise ValueError("cannot convert %s to %s" % (source, target))


serve("example-calc", "1.0", {
    "calculate": ("Evaluate an arithmetic expression exactly, for example 17*23+sqrt(2).",
                  obj({"expression": TEXT}, ["expression"]), calculate),
    "convert_units": ("Convert a number between length units (m km cm mm in ft yd mi), mass units (kg g lb oz) or temperatures (C F K).",
                      obj({"value": NUMBER, "from": TEXT, "to": TEXT}, ["value", "from", "to"]), convert),
})
