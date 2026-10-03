using System;
using System.Collections;
using ToyFormat;

namespace Fixtures;

// Each fixture is built alone by test-codegen.sh, with -define=FIXTURE_<name>. A line
// `// FIXTURE <name>: <text>` gives the text the build error must contain, or OK for a mapping that must
// build (a positive control: the checks must not reject it). Each fixture's `Use.Run` writes its type, so
// the generated bodies (planned when they are compiled) are compiled; the workspace builds only with a
// fixture defined.

class Program
{
	public static int Main()
	{
		Use.Run();
		return 0;
	}
}

[ToyObject]
class Inner
{
	public int32 Value;
}

struct Point
{
	public int32 X;
}

[ToyConverter(typeof(Point))]
struct PointToy : IToyConverter<Point>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Point target) => .Ok;
	public static void Write(Point value, ToyNode node) { }
}

// (Declared here: inside an #if-skipped region the parser trips on `int32?>`)
typealias NestedValues = List<Dictionary<String, List<int32?>>>;

static class Write<T> where T : IToySerializable, class, new, delete
{
	public static void Run()
	{
		let value = new T();
		let node = scope ToyNode();
		value.ToyWrite(node);
		value.ToyRead(node).IgnoreError();
		delete value;
	}
}

// FIXTURE OkBaseline: OK
#if FIXTURE_OkBaseline
[ToyObject(Naming = .SnakeCase)]
class Item
{
	public int32 Id;
	public String Title ~ delete _;
	public NestedValues Nested ~ delete _;
	public Dictionary<int64, Inner> ByNumber ~ delete _;
	public Point Where;
	public Inner Child ~ delete _;
}

static class Use
{
	public static void Run() => Write<Item>.Run();
}
#endif

// FIXTURE OkGenericAndSelfReference: OK
#if FIXTURE_OkGenericAndSelfReference
[ToyObject]
class Box<T>
{
	public T Value;
}

[ToyObject]
class Node
{
	public List<Node> Children ~ DeleteContainerAndItems!(_);
	public Box<int32> Boxed ~ delete _;
}

static class Use
{
	public static void Run() => Write<Node>.Run();
}
#endif

// FIXTURE OkInheritance: OK
#if FIXTURE_OkInheritance
[ToyObject]
class Base
{
	public int32 Shared;
}

[ToyObject]
class Derived : Base
{
	public int32 Own;
}

static class Use
{
	public static void Run() => Write<Derived>.Run();
}
#endif

// FIXTURE UnsupportedType: [ToyObject] Fixtures.Bad.letter: fields of type char8 are not supported
#if FIXTURE_UnsupportedType
[ToyObject]
class Bad
{
	public char8 letter;
}
#endif

// FIXTURE UnsupportedNested: [ToyObject] Fixtures.Bad.items: fields of type System.Object are not supported
#if FIXTURE_UnsupportedNested
[ToyObject]
class Bad
{
	public List<List<Object>> items;
}
#endif

// FIXTURE DuplicateName: the member "id" is mapped by both Fixtures.Bad.first and Fixtures.Bad.second
#if FIXTURE_DuplicateName
[ToyObject]
class Bad
{
	[ToyName("id")] public int32 first;
	[ToyName("id")] public int32 second;
}
#endif

// FIXTURE DuplicateAlias: the member "old" is mapped by both Fixtures.Bad.first and Fixtures.Bad.second
#if FIXTURE_DuplicateAlias
[ToyObject]
class Bad
{
	[ToyAlias("old")] public int32 first;
	[ToyAlias("old")] public int32 second;
}
#endif

// FIXTURE NamingCollision: the member "pool_size" is mapped by both Fixtures.Bad.poolSize and Fixtures.Bad.PoolSize
#if FIXTURE_NamingCollision
[ToyObject(Naming = .SnakeCase)]
class Bad
{
	public int32 poolSize;
	public int32 PoolSize;
}
#endif

// FIXTURE InheritanceCollision: the member "Shared" is mapped by both Fixtures.Base.Shared and Fixtures.Bad.other
#if FIXTURE_InheritanceCollision
[ToyObject]
class Base
{
	public int32 Shared;
}

[ToyObject]
class Bad : Base
{
	[ToyName("Shared")] public int32 other;
}
#endif

// FIXTURE BadDictionaryKey: dictionary keys must be String, integers or enums, not float
#if FIXTURE_BadDictionaryKey
[ToyObject]
class Bad
{
	public Dictionary<float, int32> map;
}
#endif

// FIXTURE TwoConverters: [ToyConverter] Both Fixtures.PointToy and Fixtures.PointToy2 are registered for Fixtures.Point
#if FIXTURE_TwoConverters
[ToyConverter(typeof(Point))]
struct PointToy2 : IToyConverter<Point>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Point target) => .Ok;
	public static void Write(Point value, ToyNode node) { }
}

[ToyObject]
class Bad
{
	public Point location;
}
#endif

// FIXTURE AbstractField: Fixtures.Shape is abstract: reading cannot create one
#if FIXTURE_AbstractField
[ToyObject]
abstract class Shape
{
	public int32 sides;
}

[ToyObject]
class Bad
{
	public Shape shape;
}
#endif

// FIXTURE ControlCharacterName: [ToyObject] Fixtures.Bad.field: the name "a
#if FIXTURE_ControlCharacterName
[ToyObject]
class Bad
{
	[ToyName("a\nb")] public int32 field;
}
#endif

#if FIXTURE_UnsupportedType || FIXTURE_UnsupportedNested || FIXTURE_DuplicateName || FIXTURE_DuplicateAlias || FIXTURE_NamingCollision || FIXTURE_InheritanceCollision || FIXTURE_BadDictionaryKey || FIXTURE_TwoConverters || FIXTURE_AbstractField || FIXTURE_ControlCharacterName
static class Use
{
	public static void Run() => Write<Bad>.Run();
}
#endif
