include:
  - machine-bootstrap.dracut
  - machine-bootstrap.recovery

machine-bootstrap-installed:
  test.nop:
    - require:
      - sls: machine-bootstrap.dracut
      - sls: machine-bootstrap.recovery
