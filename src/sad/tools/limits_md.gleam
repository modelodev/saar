import sad/docs/limits_table
import simplifile

pub fn main() {
  let toml = read_file("docs/plan/limits.toml")
  let entries = case limits_table.parse_toml(toml) {
    Ok(found) -> found
    Error(err) ->
      panic as { "LIMITS_TOML_PARSE_FAIL reason=" <> err }
  }

  let content = limits_table.render_markdown(entries)
  case simplifile.write("docs/plan/limits.md", content) {
    Ok(_) -> Nil
    Error(err) ->
      panic as {
        "LIMITS_MD_WRITE_FAIL reason=" <> simplifile.describe_error(err)
      }
  }
}

fn read_file(path: String) -> String {
  case simplifile.read(path) {
    Ok(content) -> content
    Error(err) ->
      panic as {
        "LIMITS_TOML_READ_FAIL reason=" <> simplifile.describe_error(err)
      }
  }
}
