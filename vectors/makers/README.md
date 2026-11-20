# The makers of the vector files

`../make_vectors.py` reads each `*.py` here whose name does not start with `_`, in the order of the names. One module
for each piece that brings a vector file (`windows-app-plan-v2.md`, section 5.6), so that two pieces never edit one
list. A module gives one or both of:

```python
# A file that a Swift writer test makes from FleetCore's own code: the file's name, and the test's name.
SWIFT = {"remote-install.json": "RemoteInstallVectorsTests"}


# Files that Python makes with the hub's own code: each file's name, and its value, which make_vectors.py writes as
# JSON in ASCII. Check each vector with the hub's code before it is given, as make_vectors.py does.
def python(hub, vault, releases, autopublish):
    return {"example.json": {"made_by": "app/vectors/makers/example.py"}}
```

A file name has one maker: a second one stops the run. `python3 app/vectors/make_vectors.py` writes every file, and
`--check` compares them with the committed ones.
