defmodule ElvTest do
  use ExUnit.Case

  test "product metadata is stable" do
    assert Elv.product_name() == "Elixir Luv V"
    assert Elv.short_name() == "ELV"
    assert Elv.version() == "0.1.0"
  end

  test "scanner detects incomplete V blocks" do
    refute Elv.Scanner.complete?("fn add(a int, b int) int {")
    assert Elv.Scanner.complete?("fn add(a int, b int) int {\nreturn a + b\n}")
  end

  test "split_forms keeps multi-line declarations together" do
    code = """
    import math

    fn hyp(a f64, b f64) f64 {
      return math.sqrt(a*a + b*b)
    }

    hyp(3, 4)
    """

    assert [
             "import math",
             "fn hyp(a f64, b f64) f64 {\n  return math.sqrt(a*a + b*b)\n}",
             "hyp(3, 4)"
           ] = Elv.Engine.split_forms(code)
  end

  test "V locator normalizes quoted user paths" do
    assert Elv.VLocator.normalize_user_path("\"/tmp/v\"") == Path.expand("/tmp/v")
  end
end
