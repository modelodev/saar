//// CLI-style tool to generate `docs/plan/limits.md` from `docs/plan/limits.toml`.
////
//// Responsibilities:
//// - Read the source TOML file.
//// - Delegate parsing/rendering to `sad/docs/limits_table`.
//// - Write the generated Markdown file.
////
//// Non-responsibilities:
//// - Defining the limits schema or formatting rules (owned by `sad/docs/limits_table`).
//// - Providing a stable library API for other runtime code.
////
//// Relationships:
//// - Uses `sad/docs/limits_table` as a pure helper module.

import sad/docs/limits_table
import simplifile

/// Generate `docs/plan/limits.md` from `docs/plan/limits.toml`.
///
/// This function performs file IO and will `panic` on read/parse/write failures.
///
/// Example:
/// - `gleam run -m sad/docs/limits_md`
pub fn main() {
  let toml = read_file("../../docs/plan/limits.toml")
  let content = case limits_table.render_markdown_from_toml(toml) {
    Ok(found) -> found
    Error(err) -> panic as { "LIMITS_TOML_PARSE_FAIL reason=" <> err }
  }

  case simplifile.write("../../docs/plan/limits.md", content) {
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
