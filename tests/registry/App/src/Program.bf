using System;
using ToyFormat;
using UserLib;

namespace App;

/// Written as text "<n>F" by App's own converter.
struct Fahrenheit
{
	public int32 mValue;
}

[ToyConverter(typeof(Fahrenheit))]
struct FahrenheitToy : IToyConverter<Fahrenheit>
{
	public static Result<void, ToyError> Read(ToyNode node, ref Fahrenheit target) => .Ok;
	public static void Write(Fahrenheit value, ToyNode node) => node.SetText(scope $"{value.mValue}F");
}

[ToyObject(ShowRegistry = true)]
class Station
{
	public Fahrenheit Local;
	public Celsius Outside;
	public Kelvin Inside;
}

class Program
{
	public static int Main()
	{
		Console.WriteLine($"App.Station now: {Station.ToyRegistryNow}");
		Console.WriteLine($"App.Station at apply: {Station.ToyRegistryAtApply}");
		Console.WriteLine($"UserLib.Reading now: {Reading.ToyRegistryNow}");
		Console.WriteLine($"UserLib.Reading at apply: {Reading.ToyRegistryAtApply}");
		let station = scope Station();
		station.Local.mValue = 70;
		station.Outside.mValue = 21;
		station.Inside.Value = 294;
		let node = scope ToyNode();
		station.ToyWrite(node);
		Console.WriteLine($"App.Station written: {node}");
		return 0;
	}
}
