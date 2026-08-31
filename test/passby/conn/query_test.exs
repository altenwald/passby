defmodule Passby.Conn.QueryTest do
  use ExUnit.Case, async: true

  alias Passby.Conn.Query

  test "decodes a flat key/value pair" do
    assert Query.decode("foo=bar") == %{"foo" => "bar"}
  end

  test "decodes multiple flat pairs" do
    assert Query.decode("foo=bar&baz=qux") == %{"foo" => "bar", "baz" => "qux"}
  end

  test "an empty query string decodes to an empty map" do
    assert Query.decode("") == %{}
  end

  test "the last value wins for a repeated scalar key" do
    assert Query.decode("foo=bar&foo=baz") == %{"foo" => "baz"}
  end

  test "a key without a value decodes to an empty string" do
    assert Query.decode("foo") == %{"foo" => ""}
    assert Query.decode("foo=") == %{"foo" => ""}
  end

  test "bracket notation builds nested maps" do
    assert Query.decode("filter[name]=Manuel") == %{"filter" => %{"name" => "Manuel"}}
  end

  test "bracket notation nests several levels deep" do
    assert Query.decode("a[b][c]=1") == %{"a" => %{"b" => %{"c" => "1"}}}
  end

  test "sibling nested keys are merged under the same parent" do
    assert Query.decode("filter[name]=Manuel&filter[age]=40") ==
             %{"filter" => %{"name" => "Manuel", "age" => "40"}}
  end

  test "empty brackets accumulate values into a list in order" do
    assert Query.decode("tags[]=a&tags[]=b&tags[]=c") == %{"tags" => ["a", "b", "c"]}
  end

  test "percent-encoded octets and plus signs are decoded" do
    assert Query.decode("q=hello+world&name=Jos%C3%A9") ==
             %{"q" => "hello world", "name" => "José"}
  end

  test "encoded brackets in the key are decoded before parsing" do
    assert Query.decode("filter%5Bname%5D=Manuel") == %{"filter" => %{"name" => "Manuel"}}
  end

  test "ignores empty segments between ampersands" do
    assert Query.decode("foo=bar&&baz=qux") == %{"foo" => "bar", "baz" => "qux"}
  end

  test "nesting inside lists is unspecified but does not crash" do
    # Plug documents `key[][sub]` as ambiguous/unspecified; we only guarantee a map.
    assert %{"user" => %{}} = Query.decode("user[][name]=a")
    assert Query.decode("[]=x") == %{}
  end
end
