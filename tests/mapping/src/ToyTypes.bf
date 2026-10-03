using System;
using System.Collections;
using ToyFormat;

namespace ToyTests;

enum Shade
{
	Red,
	DarkBlue
}

/// Written as a list [x, y] by its registered converter.
struct Point
{
	public int32 X;
	public int32 Y;
}

[ToyConverter(typeof(Point))]
struct PointToy : IToyConverter<Point>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Point target)
	{
		if (node.mKind != .List || node.Count != 2 || node.mItems[0].mKind != .Integer || node.mItems[1].mKind != .Integer)
			return .Err(ToyBind.Invalid("A point is a list [x, y]"));
		target.X = (int32)node.mItems[0].mInteger;
		target.Y = (int32)node.mItems[1].mInteger;
		return .Ok;
	}

	public static void Write(Point value, ToyNode node)
	{
		node.Reset();
		node.Add().SetInteger(value.X);
		node.Add().SetInteger(value.Y);
	}
}

/// An int32 written as text "<n>m", for one field only.
struct MetersToy : IToyConverter<int32>
{
	public static Result<void, ToyError> Read(ToyNode node, ref int32 target)
	{
		if (node.mKind != .Text || !node.mText.EndsWith('m'))
			return .Err(ToyBind.Invalid("Meters are text like \"12m\""));
		switch (int32.Parse(StringView(node.mText, 0, node.mText.Length - 1)))
		{
		case .Ok(let value):
			target = value;
			return .Ok;
		case .Err:
			return .Err(ToyBind.Invalid("Meters are text like \"12m\""));
		}
	}

	public static void Write(int32 value, ToyNode node)
	{
		node.SetText(scope $"{value}m");
	}
}

[ToyObject(Naming = .SnakeCase)]
class Scalars
{
	public bool IsOn;
	public int8 Small;
	public uint16 Unsigned16;
	public int64 Big;
	public uint64 Huge;
	public float Single;
	public double Double;
	public String Text ~ delete _;
	public Shade ShadeValue;
	public int32? Maybe;
	public Point Where;
	public Point? MaybeWhere;
	[ToyUseConverter(typeof(MetersToy))]
	public int32 Height;
}

[ToyObject]
struct Pos
{
	public int32 X;
	public int32 Y;
}

[ToyObject]
class Inner
{
	public String Name ~ delete _;
}

[ToyObject(Naming = .CamelCase)]
class Containers
{
	public List<int32> Numbers ~ delete _;
	public List<List<String>> Grid ~ { if (_ != null) { for (let row in _) DeleteContainerAndItems!(row); delete _; } };
	public Dictionary<String, Inner> ByName ~ DeleteDictionaryAndKeysAndValues!(_);
	public Dictionary<int32, double> ByNumber ~ delete _;
	public Dictionary<Shade, List<bool>> ByShade ~ DeleteDictionaryAndValues!(_);
	public Dictionary<uint64, String> ByHuge ~ DeleteDictionaryAndValues!(_);
	public List<Inner> Inners ~ DeleteContainerAndItems!(_);
	public List<Point> Points ~ delete _;
	public Inner Child ~ delete _;
	public Pos Place;
}

[ToyObject]
class Named
{
	[ToyName("id")]
	public int32 Identifier;
	[ToyAlias("old_name"), ToyAlias("older_name")]
	public String NewName ~ delete _;
	[ToyRequired]
	public int32 Must;
	[ToyIgnore]
	public int32 Skipped = 7;
	public static int32 sNotAField;
}

[ToyObject]
class Animal
{
	public String Name ~ delete _;
}

[ToyObject(Naming = .KebabCase)]
class Dog : Animal
{
	public int32 BarkVolume;
	public Shade CoatShade;
}

/// A generic mapped type: its unspecialized pass generates no real code.
[ToyObject]
class Box<T>
{
	public T Value;
	public List<T> More ~ delete _;
}

/// A type that holds itself (the deferred bodies avoid the type-initialization cycle).
[ToyObject]
class TreeNode
{
	public String Label ~ delete _;
	public List<TreeNode> Children ~ DeleteContainerAndItems!(_);
}
