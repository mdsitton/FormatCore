using System;
using System.Collections;
using FormatCore.Mapping;
using internal FormatCore;

namespace FormatCore.Tests;

static class MappingTests
{
	static void Check(StringView name, NamingPolicy policy, StringView expected)
	{
		let result = scope String();
		Naming.Apply(name, policy, result);
		Test.Assert(result == expected);
	}

	[Test]
	public static void Naming_SplitsWordsLikeEveryGenerator()
	{
		Check("HTTPPort", .SnakeCase, "http_port");
		Check("HTTPPort", .KebabCase, "http-port");
		Check("HTTPPort", .CamelCase, "httpPort");
		Check("HTTPPort", .PascalCase, "HttpPort");
		Check("HTTPPort", .Lower, "httpport");
		Check("HTTPPort", .AsDeclared, "HTTPPort");
		Check("poolSize", .SnakeCase, "pool_size");
		Check("pool_size", .CamelCase, "poolSize");
		Check("pool_size", .PascalCase, "PoolSize");
		Check("_x", .SnakeCase, "x");
		Check("ABC", .KebabCase, "abc");
		Check("Utf8Name", .KebabCase, "utf8-name");
		Check("value2D", .SnakeCase, "value2_d");
		Check("XMLHttpRequest", .KebabCase, "xml-http-request");
		Check("", .CamelCase, "");
	}

	[Test]
	public static void Literal_IsAlwaysValidSource()
	{
		let code = scope String();
		Literal.Append(code, "a \"quoted\" \\ path\n\t\r\x01\x7F é");
		Test.Assert(code == "\"a \\\"quoted\\\" \\\\ path\\n\\t\\r\\u{1}\\u{7F} é\"");
	}

	[Test]
	public static void IntegerBounds_UInt64StartsAtZero()
	{
		let min = scope String();
		let max = scope String();
		IntegerBounds.Range(typeof(uint64), min, max);
		Test.Assert(min == "0" && max == "int64.MaxValue");
		min.Clear();
		max.Clear();
		IntegerBounds.Range(typeof(uint), min, max);
		Test.Assert(min == "0" && max == "int64.MaxValue");
		min.Clear();
		max.Clear();
		IntegerBounds.Range(typeof(int64), min, max);
		Test.Assert(min == "int64.MinValue" && max == "int64.MaxValue");
		min.Clear();
		max.Clear();
		IntegerBounds.Range(typeof(int8), min, max);
		Test.Assert(min == "-128" && max == "127");
		min.Clear();
		max.Clear();
		IntegerBounds.Range(typeof(uint32), min, max);
		Test.Assert(min == "0" && max == "4294967295");
		min.Clear();
		max.Clear();
		IntegerBounds.RangeText(typeof(uint64), min, max);
		Test.Assert(min == "0" && max == "18446744073709551615");
		min.Clear();
		max.Clear();
		IntegerBounds.RangeText(typeof(int64), min, max);
		Test.Assert(min == "-9223372036854775808" && max == "9223372036854775807");
		Test.Assert(TypeShapes.IsUInt64(typeof(uint64)) && TypeShapes.IsUInt64(typeof(uint)) && !TypeShapes.IsUInt64(typeof(int64)));
	}

	[Test]
	public static void TypeShapes_Containers()
	{
		Test.Assert(TypeShapes.ListElement(typeof(List<int32>)) == typeof(int32));
		Test.Assert(TypeShapes.DictionaryKey(typeof(Dictionary<String, double>)) == typeof(String));
		Test.Assert(TypeShapes.DictionaryValue(typeof(Dictionary<String, double>)) == typeof(double));
		Test.Assert(TypeShapes.NullableValue(typeof(int32?)) == typeof(int32));
		Test.Assert(TypeShapes.ListElement(typeof(int32)) == null);
		Test.Assert(TypeShapes.KeyKind(typeof(String)) == .String && TypeShapes.KeyKind(typeof(bool)) == .Unsupported);
		Test.Assert(TypeShapes.ScalarKind(typeof(char8)) == .Unsupported && TypeShapes.ScalarKind(typeof(float)) == .Float);
	}

	[Test]
	public static void CodeWriter_WrapsInThePath()
	{
		let e = scope CodeWriter();
		e.mWrapMember.Set("M({0}, {1})");
		e.mWrapIndex.Set("I({0}, {1})");
		e.PushMember("\"a\"");
		e.PushIndex("_n0");
		let wrapped = scope String();
		e.Wrap("err", wrapped);
		Test.Assert(wrapped == "M(I(err, _n0), \"a\")");
		e.Pop();
		Test.Assert(e.Local("x", .. scope .()) == "_x0" && e.Local("x", .. scope .()) == "_x1");
		e.Return("\t", "err");
		Test.Assert(e.mCode == "\treturn .Err(M(err, \"a\"));\n");
	}
}
