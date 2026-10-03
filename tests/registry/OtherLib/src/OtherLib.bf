using System;
using ToyFormat;
using UserLib;

namespace OtherLib;

/// A second converter for Celsius and one for Kelvin, in a project App does not depend on: if App's
/// lookups saw them, Celsius would have two converters (a build error) and Kelvin a converter.
[ToyConverter(typeof(Celsius))]
public struct OtherCelsiusToy : IToyConverter<Celsius>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Celsius target) => .Ok;
	public static void Write(Celsius value, ToyNode node) => node.SetText("other");
}

/// A subtype App must not see.
[ToyObject]
public class Circle : Shape
{
}

[ToyConverter(typeof(Kelvin))]
public struct OtherKelvinToy : IToyConverter<Kelvin>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Kelvin target) => .Ok;
	public static void Write(Kelvin value, ToyNode node) => node.SetText("other");
}
