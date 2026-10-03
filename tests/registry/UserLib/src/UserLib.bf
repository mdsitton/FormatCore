using System;
using ToyFormat;

namespace UserLib;

/// Written as text "<n>C" by UserLib's converter.
public struct Celsius
{
	public int32 mValue;
}

[ToyConverter(typeof(Celsius))]
public struct CelsiusToy : IToyConverter<Celsius>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Celsius target)
	{
		if (node.mKind != .Text || !node.mText.EndsWith('C'))
			return .Err(ToyBind.Invalid("Celsius is text like \"21C\""));
		target.mValue = int32.Parse(StringView(node.mText, 0, node.mText.Length - 1)).GetValueOrDefault();
		return .Ok;
	}

	public static void Write(Celsius value, ToyNode node) => node.SetText(scope $"{value.mValue}C");
}

/// A mapped object; OtherLib registers a converter for it that App must not see.
[ToyObject]
public struct Kelvin
{
	public int32 Value;
}

/// A base class: its subtypes the user's project can see are UserLib's and App's, never OtherLib's.
[ToyObject]
public class Shape
{
	public int32 Sides;
}

[ToyObject]
public class Triangle : Shape
{
}

/// UserLib's own mapped type: planned with UserLib as the current project.
[ToyObject(ShowRegistry = true)]
public class Reading
{
	public Celsius Outside;
	public Kelvin Inside;
	public Shape Figure ~ delete _;
}
