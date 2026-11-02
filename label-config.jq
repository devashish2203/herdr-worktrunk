# Decode one single-line TOML setting. Keep literal strings literal and decode
# basic-string escapes without evaluating any shell syntax. Return an empty
# value on malformed input so the label formatter can warn and fall back.
def hex_number:
  ascii_downcase | explode
  | reduce .[] as $digit (0;
      . * 16 + (if $digit <= 57 then $digit - 48 else $digit - 87 end));
def basic_string:
  .[1:-1] as $body
  | [$body | match("\\\\(?:[btnfr\"\\\\]|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})|[^\\\\]"; "g") | .string] as $tokens
  | if ($tokens | join("")) != $body then error("invalid escape") else
      $tokens | map(
        if startswith("\\u") or startswith("\\U") then
          .[2:] | hex_number
          | if . == 0 or . > 1114111 or (. >= 55296 and . <= 57343)
            then error("invalid Unicode scalar") else [.] | implode end
        elif startswith("\\") then ("\"" + . + "\"") | fromjson
        else . end
      ) | join("")
    end;
try (
  split("\n")
  | map(sub("^\uFEFF"; "") | select(test("^\\s*" + $key + "\\s*=")))
  | last // ""
  | sub("^\\s*" + $key + "\\s*=\\s*"; "")
  | capture("^(?<value>\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|[^\\s#\"']+)\\s*(?:#.*)?$").value
  | if startswith("\"") then basic_string
    elif startswith("'") then .[1:-1]
    else . end
  # Labels are single-line: escapes may not smuggle in control characters.
  # Tab is the one TOML also allows unescaped.
  | if explode | any((. < 32 and . != 9) or . == 127)
    then error("control character") else . end
) catch ""
