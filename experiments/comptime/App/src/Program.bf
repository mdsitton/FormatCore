using System;
using Core;
using FormatLib;

namespace App;

[XObject]
class Point
{
	[XElement] public int x;
	[SerialName("why")] public int y;
	public String label;
}

/// Q11: a generic [XObject] type.
[XObject]
class Box<T>
{
	public T value;
}

[CoreDirect, CoreInit]
struct Direct
{
	public int a;
}

#if DEFER
[CoreDefer]
struct Deferred
{
}
#endif

#if FIXTURE_POINTER
[XObject]
class Bad
{
	public int* ptr;
}
#endif

[Converter(typeof(int))]
class AppIntConverter
{
}

class Program
{
	public static int Main()
	{
		Console.WriteLine(scope Point().XPlan);
		Console.WriteLine(scope Box<int>().XPlan);
		Console.WriteLine(scope Box<float>().XPlan);
		Console.WriteLine(scope UserLib.LibThing().XPlan);
		Console.WriteLine(scope $"Mixin in App.Point: {Point.MixinDecls}");
		Console.WriteLine(scope $"Mixin in UserLib.LibThing: {UserLib.LibThing.MixinDecls}");
		Console.WriteLine(scope $"Mixin of an emitted App.Point entry: {Point.MixinDeclsLocal}");
		Console.WriteLine(scope $"Mixin of an emitted UserLib.LibThing entry: {UserLib.LibThing.MixinDeclsLocal}");
		Console.WriteLine(Direct.CoreDirect);
		Console.WriteLine(Direct.CoreInit);
#if DEFER
		Console.WriteLine(scope $"Deferred [OnCompile] entry in App.Deferred: {Deferred.Deferred}");
#endif
		// Q8: the same Core helper at runtime
		Console.WriteLine(Naming.Kebab("RuntimeName", .. scope .()));
		return 0;
	}
}
