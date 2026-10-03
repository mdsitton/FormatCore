using System;
using Core;
using FormatLib;

namespace App;

[XObject]
class Point
{
	public int x;
}

[Converter(typeof(int))]
class AppIntConverter
{
}

class Program
{
	public static void Main()
	{
		Console.WriteLine(scope Point().XPlan);
	}
}
