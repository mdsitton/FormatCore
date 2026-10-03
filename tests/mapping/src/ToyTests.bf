using System;
using System.Collections;
using ToyFormat;

namespace ToyTests;

static class ToyTests
{
	static void Text(ToyNode node, String output)
	{
		output.Clear();
		node.ToString(output);
	}

	[Test]
	public static void Scalars_RoundTrip()
	{
		let value = scope Scalars();
		value.IsOn = true;
		value.Small = -5;
		value.Unsigned16 = 65000;
		value.Big = int64.MinValue;
		value.Huge = uint64.MaxValue;
		value.Single = 1.5f;
		value.Double = 0.25;
		value.Text = new .("hi");
		value.ShadeValue = .DarkBlue;
		value.Maybe = 3;
		value.Where = .() { X = 1, Y = 2 };
		value.Height = 12;
		let node = scope ToyNode();
		value.ToyWrite(node);
		let text = scope String();
		Text(node, text);
		Test.Assert(text == "{\"is_on\":true,\"small\":-5,\"unsigned16\":65000,\"big\":-9223372036854775808,\"huge\":18446744073709551615,\"single\":1.5,\"double\":0.25,\"text\":\"hi\",\"shade_value\":\"dark_blue\",\"maybe\":3,\"where\":[1,2],\"maybe_where\":null,\"height\":\"12m\"}");

		let back = scope Scalars();
		Test.Assert(back.ToyRead(node) case .Ok);
		Test.Assert(back.IsOn && back.Small == -5 && back.Unsigned16 == 65000 && back.Big == int64.MinValue && back.Huge == uint64.MaxValue);
		Test.Assert(back.Single == 1.5f && back.Double == 0.25 && back.Text == "hi" && back.ShadeValue == .DarkBlue);
		Test.Assert(back.Maybe == 3 && back.Where.X == 1 && back.Where.Y == 2 && !back.MaybeWhere.HasValue && back.Height == 12);
		// Absent members keep the field; null sets a Nullable to null
		node.Set("maybe").Reset();
		back.Small = 9;
		node.Get("small").SetInteger(-5);
		Test.Assert(back.ToyRead(node) case .Ok);
		Test.Assert(!back.Maybe.HasValue);
	}

	[Test]
	public static void Scalars_ErrorsCarryTheirPath()
	{
		let node = scope ToyNode();
		node.Set("small").SetInteger(200);
		let value = scope Scalars();
		switch (value.ToyRead(node))
		{
		case .Ok:
			Test.FatalError("read should fail");
		case .Err(let error):
			Test.Assert(error.mKind == .OutOfRange && error.mPath == "/small");
			Test.Assert(error.mMessage == "200 is outside the range -128 to 127");
		}
		// A uint64 field rejects a negative number (the bug the shared IntegerBounds fixes is about int64
		// bounds: uint64 has its own path); a uint16 field its range
		node.Reset();
		node.Set("huge").SetInteger(-1);
		Test.Assert(value.ToyRead(node) case .Err(let negative) && negative.mKind == .OutOfRange && negative.mPath == "/huge");
		node.Reset();
		node.Set("unsigned16").SetInteger(-1);
		Test.Assert(value.ToyRead(node) case .Err(let unsigned) && unsigned.mMessage == "-1 is outside the range 0 to 65535");
		node.Reset();
		node.Set("shade_value").SetText("green");
		Test.Assert(value.ToyRead(node) case .Err(let shade) && shade.mMessage == "\"green\" is not one of: red, dark_blue" && shade.mPath == "/shade_value");
		node.Reset();
		node.Set("where").SetText("x");
		Test.Assert(value.ToyRead(node) case .Err(let point) && point.mMessage == "A point is a list [x, y]" && point.mPath == "/where");
		node.Reset();
		node.Set("text").SetInteger(1);
		Test.Assert(value.ToyRead(node) case .Err(let text) && text.mKind == .TypeMismatch);
	}

	[Test]
	public static void Containers_NestToAnyDepth()
	{
		let value = scope Containers();
		value.Numbers = new .() { 1, 2, 3 };
		value.Grid = new .();
		value.Grid.Add(new .() { new .("a"), new .("b") });
		value.Grid.Add(new .());
		value.ByName = new .();
		let inner = new Inner();
		inner.Name = new .("x");
		value.ByName[new .("first")] = inner;
		value.ByNumber = new .();
		value.ByNumber[7] = 0.5;
		value.ByShade = new .();
		value.ByShade[.Red] = new .() { true, false };
		value.ByHuge = new .();
		value.ByHuge[uint64.MaxValue] = new .("max");
		value.Inners = new .();
		value.Inners.Add(new Inner() { Name = new .("i0") });
		value.Points = new .() { .() { X = 3, Y = 4 } };
		value.Child = new Inner() { Name = new .("child") };
		value.Place = .() { X = 5, Y = 6 };
		let node = scope ToyNode();
		value.ToyWrite(node);
		let text = scope String();
		Text(node, text);
		Test.Assert(text == "{\"numbers\":[1,2,3],\"grid\":[[\"a\",\"b\"],[]],\"byName\":{\"first\":{\"Name\":\"x\"}},\"byNumber\":{\"7\":0.5},\"byShade\":{\"red\":[true,false]},\"byHuge\":{\"18446744073709551615\":\"max\"},\"inners\":[{\"Name\":\"i0\"}],\"points\":[[3,4]],\"child\":{\"Name\":\"child\"},\"place\":{\"X\":5,\"Y\":6}}");

		let back = scope Containers();
		Test.Assert(back.ToyRead(node) case .Ok);
		Test.Assert(back.Numbers.Count == 3 && back.Numbers[2] == 3);
		Test.Assert(back.Grid.Count == 2 && back.Grid[0][1] == "b" && back.Grid[1].Count == 0);
		Test.Assert(back.ByName["first"].Name == "x" && back.ByNumber[7] == 0.5 && back.ByShade[.Red][1] == false);
		Test.Assert(back.ByHuge[uint64.MaxValue] == "max");
		Test.Assert(back.Inners[0].Name == "i0" && back.Points[0].Y == 4 && back.Child.Name == "child" && back.Place.Y == 6);
		// Reading again empties and refills the containers, deleting what they held (LeakSanitizer checks)
		Test.Assert(back.ToyRead(node) case .Ok);
		Test.Assert(back.Numbers.Count == 3 && back.Inners.Count == 1 && back.ByName.Count == 1);
		// Null drops a container; an error inside one carries the whole path
		node.Get("grid").Reset();
		node.Get("inners").mItems[0].Set("Name").SetInteger(1);
		switch (back.ToyRead(node))
		{
		case .Ok:
			Test.FatalError("read should fail");
		case .Err(let error):
			Test.Assert(error.mPath == "/inners/0/Name");
		}
		Test.Assert(back.Grid == null);
		node.Get("inners").mItems[0].Set("Name").SetText("ok");
		node.Get("byShade").mKeys[0].Set("blue");
		Test.Assert(back.ToyRead(node) case .Err(let key) && key.mPath == "/byShade/blue" && key.mMessage == "\"blue\" is not one of: red, darkBlue");
	}

	[Test]
	public static void Names_AliasesRequiredIgnored()
	{
		let node = scope ToyNode();
		node.Set("id").SetInteger(4);
		node.Set("older_name").SetText("from alias");
		node.Set("Must").SetInteger(1);
		node.Set("Skipped").SetInteger(99);
		let value = scope Named();
		Test.Assert(value.ToyRead(node) case .Ok);
		Test.Assert(value.Identifier == 4 && value.NewName == "from alias" && value.Must == 1 && value.Skipped == 7);
		// Writing renames the alias it finds and leaves the ignored field out
		value.ToyWrite(node);
		let text = scope String();
		Text(node, text);
		Test.Assert(text == "{\"id\":4,\"NewName\":\"from alias\",\"Must\":1,\"Skipped\":99}");
		let missing = scope ToyNode();
		missing.MakeMap();
		Test.Assert(value.ToyRead(missing) case .Err(let error) && error.mKind == .MissingValue && error.mMessage == "The required member \"Must\" is missing");
	}

	[Test]
	public static void Inheritance_OneMethodForTheChain()
	{
		let dog = scope Dog();
		dog.Name = new .("Rex");
		dog.BarkVolume = 11;
		dog.CoatShade = .DarkBlue;
		let node = scope ToyNode();
		// Through the base type: the override writes the whole chain, each level's naming its own
		Animal animal = dog;
		animal.ToyWrite(node);
		let text = scope String();
		Text(node, text);
		Test.Assert(text == "{\"Name\":\"Rex\",\"bark-volume\":11,\"coat-shade\":\"dark-blue\"}");
		let back = scope Dog();
		Test.Assert(back.ToyRead(node) case .Ok && back.Name == "Rex" && back.BarkVolume == 11 && back.CoatShade == .DarkBlue);
	}

	[Test]
	public static void Generics_AndSelfReference()
	{
		let boxed = scope Box<int32>();
		boxed.Value = 42;
		boxed.More = new .() { 1 };
		let node = scope ToyNode();
		boxed.ToyWrite(node);
		let text = scope String();
		Text(node, text);
		Test.Assert(text == "{\"Value\":42,\"More\":[1]}");

		let tree = scope TreeNode();
		tree.Label = new .("root");
		tree.Children = new .();
		let leaf = new TreeNode();
		leaf.Label = new .("leaf");
		tree.Children.Add(leaf);
		// Writing into a node keeps the members no field maps
		tree.ToyWrite(node);
		Text(node, text);
		Test.Assert(text == "{\"Value\":42,\"More\":[1],\"Label\":\"root\",\"Children\":[{\"Label\":\"leaf\",\"Children\":null}]}");
		let back = scope TreeNode();
		Test.Assert(back.ToyRead(node) case .Ok && back.Children[0].Label == "leaf" && back.Children[0].Children == null);
	}

	[Test]
	public static void Allocator_OwnsWhatTheReadCreates()
	{
		let node = scope ToyNode();
		let inner = node.Set("child");
		inner.Set("Name").SetText("n");
		// The allocator owns what the read creates (its destructors are not run: the Strings live in it too)
		// (corlib's BumpAllocator(.Ignore) constructor ignores its argument: set the field)
		let alloc = scope BumpAllocator();
		alloc.DestructorHandling = .Ignore;
		var value = scope Containers();
		Test.Assert(value.ToyRead(node, alloc) case .Ok);
		Test.Assert(value.Child.Name == "n");
		value.Child = null;
	}
}
