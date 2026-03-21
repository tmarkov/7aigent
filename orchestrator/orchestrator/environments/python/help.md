Any Python code. Variables and imports persist across commands.

The interpreter maintains a persistent namespace. Variables, imports, functions, and classes defined in one command are available in subsequent commands.

### Examples

  Run an expression:

    <python>
    2 + 2
    </python>

  Import a module:

    <python>
    import os
    os.getcwd()
    </python>

  Define a function and use it:

    <python>
    def greet(name):
        return f"Hello, {name}!"

    greet("world")
    </python>

  Change working directory:

    <python>
    import os
    os.chdir("/path/to/project")
    </python>
