
#===============================
# espresso
#===============================
#
include ../make.sys

#
# MAIN target
#
all: 
	$(MAKE) libblas_$(BLAS_LIBS_SWITCH) 
	$(MAKE) liblapack_$(LAPACK_LIBS_SWITCH) 
	$(MAKE) mglib
	$(MAKE) libiotk 

# BLAS
libblas : libblas_$(BLAS_LIBS_SWITCH)

libblas_external : fake_blas_external

fake_blas_external :
	touch fake_libblas.a
	rm fake_libblas.a

libblas_internal:
	if test ! -d ../BLAS; then \
	( gzip -dc archive/blas-1.tar.gz |(cd ../; tar -xvf -)); fi
	if test -e install/make_blas.inc; then \
	(cp install/make_blas.inc ../BLAS/make.inc; \
	cd ../BLAS; $(MAKE) $(BLASLIB)); else \
        (echo "no configuration file found for blas"; \
	echo "run configure from main QE dir"); fi

# LAPACK
liblapack : liblapack_$(LAPACK_LIBS_SWITCH) 

liblapack_external : fake_lapack_external

fake_lapack_external :
	touch fake_liblapack.a
	rm fake_liblapack.a

liblapack_internal:
	if test ! -d ../lapack-3.2; then \
	( gzip -dc archive/lapack-3.2.tar.gz | (cd ../; tar -xvf -)); fi
	if test -e install/make_lapack.inc; then \
	(cp install/make_lapack.inc ../lapack-3.2/make.inc; \
	cp install/Makefile_lapack ../lapack-3.2/SRC/Makefile; \
        cp install/Makefile_lapack_testing_lin ../lapack-3.2/TESTING/LIN/Makefile; \
	cd ../lapack-3.2; $(MAKE) lapacklib); else \
        (echo "no configuration file found for lapack"; \
        echo "run configure from main QE dir"); fi

#Multigrid
mglib:
	if (test ! -d ../Multigrid || \
	test ! -e ../Multigrid/Makefile); then \
	( cat archive/multigrid.tar | (cd ../; tar -xvf -)) ; fi
	cd ../Multigrid; $(MAKE) all; 
#Multigrid
libiotk:
	if test ! -d ../S3DE; then \
	(gzip -dc archive/iotk-1.2.beta.tar.gz | (cd ../; tar -xvf -)) ; \
	if test -e install/Makefile_iotk; then \
        (cp install/Makefile_iotk ../S3DE/iotk/src/Makefile); fi; \
	if test -e install/iotk_config.h; then \
	(cp install/iotk_config.h ../S3DE/iotk/include/iotk_config.h); fi; fi
	cd ../S3DE/iotk/src; $(MAKE) lib+util; 
	cd ../bin; ln -fs ../S3DE/iotk/tools/iotk .; \
	ln -fs ../S3DE/iotk/src/iotk.x .; \
	ln -fs ../S3DE/iotk/src/iotk_print_kinds.x .; \
	cd ../; ln -fs S3DE/iotk iotk
###################################
# cleaning
###################################
# each lib independently
blas_clean:
	if test -d ../BLAS; then (cd ../BLAS; $(MAKE) clean); fi
blas_veryclean:
	if test -d ../BLAS; then (rm -R -f ../BLAS); fi
lapack_clean:
	if test -d ../lapack-3.2; then (cd ../lapack-3.2; $(MAKE) clean); fi
lapack_veryclean:
	if test -d ../lapack-3.2; then (rm -R -f ../lapack-3.2); fi
multigrid_clean:
	if (test -d ../Multigrid && \
	test -e ../Multigrid/Makefile) ; then \
	(cd ../Multigrid; $(MAKE) clean); fi
multigrid_veryclean:
	if test -d ../Multigrid; then (rm -R -f ../Multigrid); fi
iotk_clean:
	if test -d ../S3DE; then (cd ../S3DE; $(MAKE) clean); fi
	if test -e ../S3DE/iotk/src/iotk.x; then \
	rm -f ../S3DE/iotk/src/iotk.x; fi
	(rm -f ../bin/iotk; \
	rm -f ../bin/iotk.x; \
	rm -f ../bin/iotk_print_kinds.x)
iotk_veryclean:
	if test -d ../S3DE; then (rm -R -f ../S3DE); fi
	if test -e ../S3DE/iotk/src/iotk.x; then (rm -f ../S3DE/iotk/src/iotk.x); fi
	rm -f ../bin/iotk; \
	rm -f ../bin/iotk.x; \
	rm -f ../bin/iotk_print_kinds.x; \
	rm -f ../iotk

# general cleaning
clean: blas_clean lapack_clean multigrid_clean iotk_clean
veryclean: blas_veryclean lapack_veryclean multigrid_veryclean iotk_veryclean
