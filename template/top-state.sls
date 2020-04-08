base:

  # physical machine
  'virtual:physical':
    - match: grain
    - hardware

  # virtual machine
  'P@virtual:(?!physical)':
    - match: compound
    - virtual

  # any machine type with a kernel (including virtual) but not on lxc (is same kernel)
  'P@virtual:(?!LXC)':
    - match: compound
    - kernel
    - haveged
    - acpi

  # ubuntu specific
  'os:Ubuntu':
    - match: grain
    - ubuntu

  # any
  '*':
    - locale
    - tools
    - ssh
    - machine-bootstrap

  # custom states
  # to disable custom states from running,
  # add pillar='{"disable_custom": true}' to execution
  'not I@disable_custom:true':
    - match: compound
    - custom
