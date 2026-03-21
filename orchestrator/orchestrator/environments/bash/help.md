Any bash command. Use & for background jobs.

The shell maintains state between commands including working directory, environment variables, and shell functions.

### Examples

  Run a command:

    <bash>
    echo "hello world"
    </bash>

  Change directory:

    <bash>
    cd /path/to/project
    </bash>

  Set an environment variable:

    <bash>
    export MY_VAR=value
    </bash>

  Start a background job:

    <bash>
    ./long_running_script.sh &
    </bash>
