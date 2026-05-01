# EDA Tool

CLI-driven electronic design automation for schematic capture using S-expression syntax.

## sexpr/tokenizer

- Tokenizes parentheses and atoms from S-expression input
- Tokenizes integer and float numbers with optional unit suffixes
- Skips line comments starting with semicolon
- Tokenizes arithmetic operators as distinct tokens
- Tokenizes comparison operators as distinct tokens
- Tracks line and column position for each token
- Tokenizes KiCad-style unquoted filenames containing +

## sexpr/parser

- Parses a simple S-expression list into an AST node
- Parses nested S-expression lists into a tree
- Parses numbers and unit values into typed AST nodes
- Parses input containing comments by ignoring them
- Parses multiple top-level forms into separate AST nodes
- Identifies forms by head atom via isForm helper

## sexpr/printer

- Prints a simple list as a single-line S-expression string
- Prints short nested lists inline on one line
- Prints long nested lists with multiline indentation
- Round-trips parse to print to parse producing identical AST

## sexpr/ast

- Constructs typed AST nodes for list, atom, string, int, float, and unit values

## eval/builtins

- Evaluates arithmetic operations on numeric values
- Evaluates a voltage divider formula combining arithmetic operators
- Evaluates comparison operations returning boolean results
- Evaluates logic operations on boolean values

## eval/fmt

- Formats voltage values with SI prefix and V suffix
- Formats resistance values with SI prefix and ohm suffix
- Formats capacitance values with SI prefix and F suffix
- Formats amperage values with SI prefix (uA/mA/A)
- Formats tilde escape sequences in format strings
- Formats mixed specifiers in a single format string

## eval/env

- Stores and retrieves values by name in an environment
- Resolves names through a parent environment chain

## eval/evaluator

- Evaluates arithmetic expressions from S-expression AST
- Evaluates let bindings that define named values in scope
- Evaluates if conditionals selecting a branch by predicate
- Evaluates fmt expressions producing formatted strings
- Evaluates assert-range that passes when value is in bounds
- Evaluates assert-range that fails when value is out of bounds
- parseId extracts 8-char ID from form children
- parseId returns null when no ID present
- deriveChildId produces the same child ID when called with identical inputs
- deriveChildId produces unique child IDs across different index values
- generateId produces 8-char hex starting with letter
- isStandardRefDes distinguishes standard from descriptive labels

## id_insert

- findMatchingClose finds correct closing paren
- findMatchingClose handles strings containing parens

## convert/footprint

- Converts a KiCad footprint file into S-expression format

## convert/symbol

- Converts a KiCad symbol file into S-expression format

## convert/alt-functions

- Parses a long-format CSV with position/function/etype columns
- Parses ST open-pin-data XML into alt-function rows
- Merges CSV alternate-function rows into an existing pinout file

## emit

- Emits a placeholder for an empty resolved design

## parts

- Returns null when looking up a missing component family
- Matches component attributes against filter criteria
- Picks the preferred component from matching candidates

## export_kicad

- Generates a KiCad netlist from a resolved design
- Exports a KiCad footprint mod file from footprint data

## board

- Evaluates board form with design reference and outline

## layout

- Parses placement from layout source
- Parses trace from layout source

## render_pcb_json

- Parses footprint geometry from sexp source

## export_kicad_pcb

- Generates a KiCad PCB file from a resolved design
- Extracts footprint placements from existing PCB by canopy_uuid
- Generates deterministic sub-UUIDs for pad elements

## bom

- Generates deterministic UUIDs in the expected format
- Loads an empty BOM file without error
- Detects net overlap between components

## render_svg

Public functions: renderSchematic

## render_svg/draw

- Keeps short pin lists verbatim
- Collapses four or more pins to an Nx summary

## erc

- Emits power_budget error when load max exceeds source max
- Emits power_budget warning when typ load is above 80 percent of source typ
- Emits no power_budget violation when load is well below source capacity
- Requires pin function assertion when pinout defines alternates
- Allows pins without alternates to omit (as ...)
- Accepts multiple asserted functions on a single pin
- Rejects asserted function that is not in the pinout

## eval/power_budget

Public functions: analyze

## eval/power_sequencing

Public functions: analyze

- Emits one always_on row per sub-block output with no enable
- Orders dependent rail after its enable source
- Flags enable that never resolves to a known rail
- Routes enable through PG signal to source rail

## review

- slugify converts section titles to anchor-safe identifiers
- isoTimestamp formats epoch seconds as ISO-8601 UTC
- buildSummary marks status=pass when no errors or warnings
- buildSummary marks status=warn on warning-level violations
- buildSummary marks status=fail on error-level violations
- buildSummary counts critical hub instances and lists those missing requirements
- buildSummary skips instances whose component sets ignore-requirements
- buildTestPoints collects testpoint instances with pin 1 net
- buildTestPoints ignores non-testpoints

## render_system_svg

- Maps section categories to macro columns
- Builds one chip per section classified by name
- Recurses into sub-sections to expose each as its own chip
- Emits a chip per sub-block classified by its name
- Falls back to one synthetic chip when a design has no sections

## review_json

Public functions: renderToJson

## review_md

Public functions: renderToMarkdown

- emits markdown header for design name

## req_checks

Public functions: runChecks, deinit, parseMicroFarads, parseOhms, parseMicroHenries

- parseMicroFarads handles SI-suffixed cap values
- parseOhms handles SI prefixes for resistor values
- parseMicroHenries handles SI-suffixed inductor values

## review_html

Public functions: renderToHtml

## review_state

Public functions: loadState, saveState, reconcile, addItem, toggleItem, deleteItem, setApproval, renderState

- saveState then loadState round-trips a checklist
- loadState returns empty state when file is missing
- reconcile drops stale slugs and synthesises empty entries
- safeName rejects path-traversal attempts
- addItem appends a new checklist item with a fresh id

## serve

Public functions: notFound, serve

## serve/vfs

Public functions: readFile, writeFile, editFile, listDir, glob, deleteFile, moveFile, dirtyDesignsForPath

- rejects parent traversal
- rejects absolute paths
- rejects dot-prefixed segments
- rejects NUL and backslash bytes
- allows project source and library paths
- denies auth and oauth paths
- denies writes to history and out
- denies writes to .layout files
- matches basic glob patterns
- import detection respects word boundaries
- denialHint redirects bare lib listing to list_library
- denialHint redirects PDF writes to the disk/browser route
- libraryEntityFor classifies library subdirs
- denies write_file on lib/datasheets (PDFs are read-only via MCP)

## serve/component_info

Public functions: describeComponent

- kebab-cases every Check variant tag
- findSourceComment finds the source-of-truth path
- parsePinoutBody normalises pin ID shapes

## serve/upload_datasheet

Public functions: uploadDatasheetApi, listDatasheetsApi, serveDatasheetApi, isPdfMagic, sanitizeFilename, storeDatasheet, storeErrorBody, storeErrorStatus

- sanitize strips path segments
- sanitize forces .pdf extension
- sanitize replaces unsafe chars
- isPdfMagic gates non-PDF input
