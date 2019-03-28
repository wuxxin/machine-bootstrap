base:

  # physical machine
  'virtual:physical':
    - match: grain
    - hardware

  # virtual machine
  'P@virtual:(?!physical)':
    - match: compound
    - virtual

  # any machine type (including virtual) but not on lxc (is same kernel)
  'P@virtual:(?!LXC)':
    - match: compound
    - haveged
    - kernel
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
    - custom
