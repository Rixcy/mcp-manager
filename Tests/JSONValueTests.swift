import Foundation

func runJSONValueTests() {
    test("JSONValue: parse keeps booleans, integers and doubles apart") {
        let value = try JSONValue.parse(#"{"flag": true, "count": 3, "ratio": 0.5, "whole": 2.0, "none": null}"#)
        expectEqual(value["flag"], .bool(true))
        expectEqual(value["count"], .int(3))
        expectEqual(value["ratio"], .double(0.5))
        expectEqual(value["whole"]?.intValue, 2)
        expectEqual(value["none"], .null)
    }

    test("JSONValue: compact encoding stays on one line even when strings hold newlines") {
        let value: JSONValue = ["text": "line one\nline two\r\n", "tab": "a\tb", "nested": ["x": [1, 2]]]
        let encoded = value.jsonString()
        expectTrue(!encoded.contains("\n") && !encoded.contains("\r"), "raw line break in \(encoded)")
        expectEqual(try JSONValue.parse(encoded), value)
    }

    test("JSONValue: escapes quotes, backslashes, control characters and line separators") {
        let value: JSONValue = .string("say \"hi\" \\ \u{01} \u{2028}")
        let backslash = "\\"
        let expected = "\"say " + backslash + "\"hi" + backslash + "\" " + backslash + backslash + " "
            + backslash + "u0001 " + backslash + "u2028\""
        expectEqual(value.jsonString(), expected)
        expectEqual(try JSONValue.parse(value.jsonString()), value)
    }

    test("JSONValue: pretty output sorts keys and indents by two spaces") {
        let value: JSONValue = ["b": [1, ["c": true]], "a": "x", "empty": [:], "list": []]
        expectEqual(value.jsonString(pretty: true), """
        {
          "a": "x",
          "b": [
            1,
            {
              "c": true
            }
          ],
          "empty": {},
          "list": []
        }
        """)
    }

    test("JSONValue: NaN and infinity encode as null, whole doubles without a fraction") {
        expectEqual(JSONValue.array([.double(.nan), .double(.infinity), .double(4.0), .double(1.25)]).jsonString(),
                    "[null,null,4,1.25]")
    }

    test("JSONValue: a round trip through JSONSerialization keeps the value") {
        let value: JSONValue = ["s": "é", "i": -7, "d": 3.5, "b": false, "n": nil, "a": [[:], []]]
        let data = try JSONSerialization.data(withJSONObject: value.anyValue)
        expectEqual(try JSONValue.parse(data), value)
    }

    test("JSONValue: parse errors carry the reason") {
        do {
            _ = try JSONValue.parse("{\"open\": ")
            fail("parsed truncated JSON")
        } catch let error as JSONParseError {
            expectTrue(!error.description.isEmpty, "empty parse error")
        }
    }
}
