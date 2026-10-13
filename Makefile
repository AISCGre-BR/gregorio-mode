EMACS ?= emacs
BATCH := $(EMACS) -Q --batch -L .

SRCS := gregorio-mode.el gregorio-ts-mode.el
TESTS := test/gregorio-mode-test.el

.PHONY: all compile test checkdoc clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRCS)

test:
	$(BATCH) -L test -l $(TESTS) -f ert-run-tests-batch-and-exit

checkdoc:
	$(BATCH) --eval '(dolist (f (list $(foreach s,$(SRCS),"$(s)"))) (checkdoc-file f))'

clean:
	rm -f *.elc test/*.elc
