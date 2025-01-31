# Test Information

Pytest test suite for the AVS quote search example application.
These tests are simple and used by the devs to verify the examples are functional.
They should not be used as a model for your production tests.

## Setup

Create a virtual environment and install the requirements in requirements.txt.
```shell
pip install -r requirements.txt
```

Run the quote search example app so that it listens on port 8080.
If it is not running on port 8080, you can run the tests with the --app-address option set to the correct address:port.

Then run the tests with pytest.
```shell
python -m pytest .
```