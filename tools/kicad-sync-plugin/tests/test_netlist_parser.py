from plugins import netlist_parser


SAMPLE = """
(export (version "E")
  (design (source "demo") (tool "canopy-eda"))
  (components
    (comp (ref "R1")
      (value "10k")
      (footprint "footprints:R_0402_1005Metric")
      (tstamp "uuid-r1-0001")
      (property (name "MPN") (value "RC0402FR-0710KL")))
    (comp (ref "C1")
      (value "100nF")
      (footprint "footprints:C_0402_1005Metric")
      (tstamp "uuid-c1-0001")))
  (nets
    (net (code "0") (name "")
      (node (ref "U1") (pin "43")))
    (net (code "1") (name "VDD")
      (node (ref "R1") (pin "1"))
      (node (ref "C1") (pin "1")))
    (net (code "2") (name "GND")
      (node (ref "R1") (pin "2"))
      (node (ref "C1") (pin "2")))))
"""


def test_parse_components():
    nl = netlist_parser.parse(SAMPLE)
    refs = [c.ref for c in nl.components]
    assert refs == ["R1", "C1"]
    r1 = nl.components[0]
    assert r1.value == "10k"
    assert r1.footprint == "footprints:R_0402_1005Metric"
    assert r1.uuid == "uuid-r1-0001"
    assert r1.properties == {"MPN": "RC0402FR-0710KL"}


def test_parse_nets():
    nl = netlist_parser.parse(SAMPLE)
    names = [n.name for n in nl.nets]
    assert "VDD" in names and "GND" in names
    vdd = next(n for n in nl.nets if n.name == "VDD")
    assert {(nd.ref, nd.pin) for nd in vdd.nodes} == {("R1", "1"), ("C1", "1")}


def test_pad_net_map():
    nl = netlist_parser.parse(SAMPLE)
    m = netlist_parser.pad_net_map(nl)
    assert m[("R1", "1")] == "VDD"
    assert m[("C1", "2")] == "GND"
    # Unconnected (empty-name) nets are excluded.
    assert ("U1", "43") not in m


def test_skips_corrupted_property_names():
    text = """
    (export (version "E")
      (components
        (comp (ref "R1") (value "10k") (footprint "x:y") (tstamp "u")
          (property (name "Good") (value "ok"))
          (property (name "Bad\xff\xff") (value "x"))))
      (nets))
    """
    nl = netlist_parser.parse(text)
    assert nl.components[0].properties == {"Good": "ok"}
