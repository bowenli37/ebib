# Ebib #

(c) 2003-2013 Joost Kremers

Note: this is an test version of Ebib that uses strings for storing entry
types, field names and string abbreviations. Other than that, everything
works the same as on the master branch. The reason for switching to strings
is that it makes it easier to interoperate with Emacs' `bibtex.el`. The
idea is for example to adopt the entry type definitions used by
`bibtex.el`, rather than using separate entry type definitions.

If you want to use this branch, make sure your customisations are updated:
some of the customisation options used to take symbols as values, but now
take strings. If you run into any problems, please report them on the
issues page.



# Original README #

Ebib is a BibTeX database manager that runs in GNU Emacs. With Ebib, you
can create and manage .bib-files, all within Emacs. It supports @string and
@preamble definitions, multi-line field values, searching, and integration
with Emacs' (La)TeX mode.

See the Ebib manual for usage and installation instructions.

The latest release version of Ebib, contact information and mailing list
can be found at <http://ebib.sourceforge.net>. Development sources can be
found at <https://github.com/joostkremers/ebib>.
