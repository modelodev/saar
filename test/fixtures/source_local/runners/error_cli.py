"""Runner that always returns an error."""
import json
import sys


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    if "--provision" in sys.argv:
        emit({"t": "provision_result", "status": "success", "log_files": []})
        return 0

    _input_json = sys.stdin.read()
    emit(
        {
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "agent_error", "message": "boom"},
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
