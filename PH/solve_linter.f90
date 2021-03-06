!
! Copyright (C) 2001-2009 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!-----------------------------------------------------------------------
SUBROUTINE solve_linter (irr, imode0, npe, drhoscf)
  !-----------------------------------------------------------------------
  !
  !    Driver routine for the solution of the linear system which
  !    defines the change of the wavefunction due to a lattice distorsion
  !    It performs the following tasks:
  !     a) computes the bare potential term Delta V | psi >
  !        and an additional term in the case of US pseudopotentials
  !     b) adds to it the screening term Delta V_{SCF} | psi >
  !     c) applies P_c^+ (orthogonalization to valence states)
  !     d) calls cgsolve_all to solve the linear system
  !     e) computes Delta rho, Delta V_{SCF} and symmetrizes them
  !

  USE kinds,                ONLY : DP
  USE ions_base,            ONLY : nat, ntyp => nsp, ityp
  USE io_global,            ONLY : stdout, ionode
  USE io_files,             ONLY : prefix, iunigk, diropn
  USE check_stop,           ONLY : check_stop_now
  USE wavefunctions_module, ONLY : evc
  USE constants,            ONLY : degspin
  USE cell_base,            ONLY : tpiba2
  USE ener,                 ONLY : ef
  USE klist,                ONLY : lgauss, degauss, ngauss, xk, wk
  USE grid_dimensions,      ONLY : nrxx
  USE gvect,                ONLY : g
  USE gsmooth,              ONLY : doublegrid
  USE smooth_grid_dimensions,ONLY: nrxxs
  USE lsda_mod,             ONLY : lsda, nspin, current_spin, isk
  USE spin_orb,             ONLY : domag
  USE wvfct,                ONLY : nbnd, npw, npwx, igk,g2kin,  et
  USE scf,                  ONLY : rho
  USE uspp,                 ONLY : okvan, vkb
  USE uspp_param,           ONLY : upf, nhm, nh
  USE noncollin_module,     ONLY : noncolin, npol, nspin_mag
  USE paw_variables,        ONLY : okpaw
  USE paw_onecenter,        ONLY : paw_dpotential, paw_dusymmetrize, &
                                   paw_dumqsymmetrize
  USE control_ph,           ONLY : rec_code, niter_ph, nmix_ph, elph, tr2_ph, &
                                   alpha_pv, lgamma, lgamma_gamma, convt, &
                                   nbnd_occ, alpha_mix, ldisp, rec_code_read, &
                                   where_rec, flmixdpot, ext_recover
  USE nlcc_ph,              ONLY : nlcc_any
  USE units_ph,             ONLY : iudrho, lrdrho, iudwf, lrdwf, iubar, lrbar, &
                                   iuwfc, lrwfc, iunrec, iudvscf, &
                                   this_pcxpsi_is_on_file
  USE output,               ONLY : fildrho, fildvscf
  USE phus,                 ONLY : int3_paw, becsumort
  USE eqv,                  ONLY : dvpsi, dpsi, evq, eprec
  USE qpoint,               ONLY : xq, npwq, igkq, nksq, ikks, ikqs
  USE modes,                ONLY : npertx, npert, u, t, irotmq, tmq, &
                                   minus_q, irgq, nsymq, rtau
  USE recover_mod,          ONLY : read_rec, write_rec

  ! used oly to write the restart file
  USE mp_global,            ONLY : inter_pool_comm, intra_pool_comm
  USE mp,                   ONLY : mp_sum
  !
  implicit none

  integer :: irr, npe, imode0
  ! input: the irreducible representation
  ! input: the number of perturbation
  ! input: the position of the modes

  complex(DP) :: drhoscf (nrxx, nspin_mag, npe)
  ! output: the change of the scf charge

  real(DP) , allocatable :: h_diag (:,:)
  ! h_diag: diagonal part of the Hamiltonian
  real(DP) :: thresh, anorm, averlt, dr2
  ! thresh: convergence threshold
  ! anorm : the norm of the error
  ! averlt: average number of iterations
  ! dr2   : self-consistency error
  real(DP) :: dos_ef, weight, aux_avg (2)
  ! Misc variables for metals
  ! dos_ef: density of states at Ef
  real(DP), external :: w0gauss, wgauss
  ! functions computing the delta and theta function

  complex(DP), allocatable, target :: dvscfin(:,:,:)
  ! change of the scf potential
  complex(DP), pointer :: dvscfins (:,:,:)
  ! change of the scf potential (smooth part only)
  complex(DP), allocatable :: drhoscfh (:,:,:), dvscfout (:,:,:)
  ! change of rho / scf potential (output)
  ! change of scf potential (output)
  complex(DP), allocatable :: ldos (:,:), ldoss (:,:), mixin(:), mixout(:), &
       dbecsum (:,:,:,:), dbecsum_nc(:,:,:,:,:), aux1 (:,:)
  ! Misc work space
  ! ldos : local density of states af Ef
  ! ldoss: as above, without augmentation charges
  ! dbecsum: the derivative of becsum
  REAL(DP), allocatable :: becsum1(:,:,:)

  logical :: conv_root,  & ! true if linear system is converged
             exst,       & ! used to open the recover file
             lmetq0        ! true if xq=(0,0,0) in a metal

  integer :: kter,       & ! counter on iterations
             iter0,      & ! starting iteration
             ipert,      & ! counter on perturbations
             ibnd,       & ! counter on bands
             iter,       & ! counter on iterations
             lter,       & ! counter on iterations of linear system
             ltaver,     & ! average counter
             lintercall, & ! average number of calls to cgsolve_all
             ik, ikk,    & ! counter on k points
             ikq,        & ! counter on k+q points
             ig,         & ! counter on G vectors
             ndim,       &
             is,         & ! counter on spin polarizations
             nt,         & ! counter on types
             na,         & ! counter on atoms
             nrec, nrec1,& ! the record number for dvpsi and dpsi
             ios,        & ! integer variable for I/O control
             mode          ! mode index

  real(DP) :: tcpu, get_clock ! timing variables

  external ch_psi_all, cg_psi
  !
  IF (rec_code_read > 20 ) RETURN

  call start_clock ('solve_linter')
  allocate (dvscfin ( nrxx , nspin_mag , npe))
  if (doublegrid) then
     allocate (dvscfins ( nrxxs , nspin_mag , npe))
  else
     dvscfins => dvscfin
  endif
  allocate (drhoscfh ( nrxx , nspin_mag , npe))
  allocate (dvscfout ( nrxx , nspin_mag , npe))
  allocate (dbecsum ( (nhm * (nhm + 1))/2 , nat , nspin_mag , npe))
  IF (okpaw) THEN
     allocate (mixin(nrxx*nspin_mag*npe+(nhm*(nhm+1)*nat*nspin_mag*npe)/2) )
     allocate (mixout(nrxx*nspin_mag*npe+(nhm*(nhm+1)*nat*nspin_mag*npe)/2) )
     mixin=(0.0_DP,0.0_DP)
  ENDIF
  IF (noncolin) allocate (dbecsum_nc (nhm,nhm, nat , nspin , npe))
  allocate (aux1 ( nrxxs, npol))
  allocate (h_diag ( npwx*npol, nbnd))
  !
  if (rec_code_read == 10.AND.ext_recover) then
     ! restart from Phonon calculation
     IF (okpaw) THEN
        CALL read_rec(dr2, iter0, npe, dvscfin, dvscfins, drhoscfh, dbecsum)
        CALL setmixout(npe*nrxx*nspin_mag,(nhm*(nhm+1)*nat*nspin_mag*npe)/2, &
                    mixin, dvscfin, dbecsum, ndim, -1 )
     ELSE
        CALL read_rec(dr2, iter0, npe, dvscfin, dvscfins, drhoscfh)
     ENDIF
     rec_code=0
  else
    iter0 = 0
    convt =.FALSE.
    where_rec='no_recover'
  endif

  IF (ionode .AND. fildrho /= ' ') THEN
     INQUIRE (UNIT = iudrho, OPENED = exst)
     IF (exst) CLOSE (UNIT = iudrho, STATUS='keep')
     CALL diropn (iudrho, TRIM(fildrho)//'.u', lrdrho, exst)
  END IF

  IF (convt) GOTO 155

  !
  ! if q=0 for a metal: allocate and compute local DOS at Ef
  !

  lmetq0 = lgauss.and.lgamma
  if (lmetq0) then
     allocate ( ldos ( nrxx  , nspin_mag) )
     allocate ( ldoss( nrxxs , nspin_mag) )
     IF (okpaw) THEN
        allocate (becsum1 ( (nhm * (nhm + 1))/2 , nat , nspin_mag))
        call localdos_paw ( ldos , ldoss , becsum1, dos_ef )
     ELSE
        call localdos ( ldos , ldoss , dos_ef )
     ENDIF
  endif
  !
  !
  ! In this case it has recovered after computing the contribution
  ! to the dynamical matrix. This is a new iteration that has to
  ! start from the beginning.
  !
  IF (iter0==-1000) iter0=0
  !
  !   The outside loop is over the iterations
  !
  do kter = 1, niter_ph
     iter = kter + iter0

     ltaver = 0

     lintercall = 0
     drhoscf(:,:,:) = (0.d0, 0.d0)
     dbecsum(:,:,:,:) = (0.d0, 0.d0)
     IF (noncolin) dbecsum_nc = (0.d0, 0.d0)
     !
     if (nksq.gt.1) rewind (unit = iunigk)
     do ik = 1, nksq
        if (nksq.gt.1) then
           read (iunigk, err = 100, iostat = ios) npw, igk
100        call errore ('solve_linter', 'reading igk', abs (ios) )
        endif
        if (lgamma)  npwq = npw
        ikk = ikks(ik)
        ikq = ikqs(ik)
        if (lsda) current_spin = isk (ikk)
        if (.not.lgamma.and.nksq.gt.1) then
           read (iunigk, err = 200, iostat = ios) npwq, igkq
200        call errore ('solve_linter', 'reading igkq', abs (ios) )

        endif
        call init_us_2 (npwq, igkq, xk (1, ikq), vkb)
        !
        ! reads unperturbed wavefuctions psi(k) and psi(k+q)
        !
        if (nksq.gt.1) then
           if (lgamma) then
              call davcio (evc, lrwfc, iuwfc, ikk, - 1)
           else
              call davcio (evc, lrwfc, iuwfc, ikk, - 1)
              call davcio (evq, lrwfc, iuwfc, ikq, - 1)
           endif

        endif
        !
        ! compute the kinetic energy
        !
        do ig = 1, npwq
           g2kin (ig) = ( (xk (1,ikq) + g (1, igkq(ig)) ) **2 + &
                          (xk (2,ikq) + g (2, igkq(ig)) ) **2 + &
                          (xk (3,ikq) + g (3, igkq(ig)) ) **2 ) * tpiba2
        enddo

        h_diag=0.d0
        do ibnd = 1, nbnd_occ (ikk)
           do ig = 1, npwq
              h_diag(ig,ibnd)=1.d0/max(1.0d0,g2kin(ig)/eprec(ibnd,ik))
           enddo
           IF (noncolin) THEN
              do ig = 1, npwq
                 h_diag(ig+npwx,ibnd)=1.d0/max(1.0d0,g2kin(ig)/eprec(ibnd,ik))
              enddo
           END IF
        enddo
        !
        ! diagonal elements of the unperturbed hamiltonian
        !
        do ipert = 1, npe
           mode = imode0 + ipert
           nrec = (ipert - 1) * nksq + ik
           !
           !  and now adds the contribution of the self consistent term
           !
           if (where_rec =='solve_lint'.or.iter>1) then
              !
              ! After the first iteration dvbare_q*psi_kpoint is read from file
              !
              call davcio (dvpsi, lrbar, iubar, nrec, - 1)
              !
              ! calculates dvscf_q*psi_k in G_space, for all bands, k=kpoint
              ! dvscf_q from previous iteration (mix_potential)
              !
              call start_clock ('vpsifft')
              do ibnd = 1, nbnd_occ (ikk)
                 call cft_wave (evc (1, ibnd), aux1, +1)
                 call apply_dpot(nrxxs, aux1, dvscfins(1,1,ipert), current_spin)
                 call cft_wave (dvpsi (1, ibnd), aux1, -1)
              enddo
              call stop_clock ('vpsifft')
              !
              !  In the case of US pseudopotentials there is an additional
              !  selfconsist term which comes from the dependence of D on
              !  V_{eff} on the bare change of the potential
              !
              call adddvscf (ipert, ik)
           else
              !
              !  At the first iteration dvbare_q*psi_kpoint is calculated
              !  and written to file
              !
              call dvqpsi_us (ik, u (1, mode),.false. )
              call davcio (dvpsi, lrbar, iubar, nrec, 1)
           endif
           !
           ! Ortogonalize dvpsi to valence states: ps = <evq|dvpsi>
           ! Apply -P_c^+.
           !
           CALL orthogonalize(dvpsi, evq, ikk, ikq, dpsi)
           !
           if (where_rec=='solve_lint'.or.iter > 1) then
              !
              ! starting value for delta_psi is read from iudwf
              !
              nrec1 = (ipert - 1) * nksq + ik
              call davcio ( dpsi, lrdwf, iudwf, nrec1, -1)
              !
              ! threshold for iterative solution of the linear system
              !
              thresh = min (1.d-1 * sqrt (dr2), 1.d-2)
           else
              !
              !  At the first iteration dpsi and dvscfin are set to zero
              !
              dpsi(:,:) = (0.d0, 0.d0)
              dvscfin (:, :, ipert) = (0.d0, 0.d0)
              !
              ! starting threshold for iterative solution of the linear system
              !
              thresh = 1.0d-2
           endif

           !
           ! iterative solution of the linear system (H-eS)*dpsi=dvpsi,
           ! dvpsi=-P_c^+ (dvbare+dvscf)*psi , dvscf fixed.
           !
           conv_root = .true.

           call cgsolve_all (ch_psi_all, cg_psi, et(1,ikk), dvpsi, dpsi, &
                             h_diag, npwx, npwq, thresh, ik, lter, conv_root, &
                             anorm, nbnd_occ(ikk), npol )

           ltaver = ltaver + lter
           lintercall = lintercall + 1
           if (.not.conv_root) WRITE( stdout, '(5x,"kpoint",i4," ibnd",i4,  &
                &              " solve_linter: root not converged ",e10.3)') &
                &              ik , ibnd, anorm
           !
           ! writes delta_psi on iunit iudwf, k=kpoint,
           !
           nrec1 = (ipert - 1) * nksq + ik
           !               if (nksq.gt.1 .or. npert(irr).gt.1)
           call davcio (dpsi, lrdwf, iudwf, nrec1, + 1)
           !
           ! calculates dvscf, sum over k => dvscf_q_ipert
           !
           weight = wk (ikk)
           IF (noncolin) THEN
              call incdrhoscf_nc(drhoscf(1,1,ipert),weight,ik, &
                                 dbecsum_nc(1,1,1,1,ipert), dpsi)
           ELSE
              call incdrhoscf (drhoscf(1,current_spin,ipert), weight, ik, &
                            dbecsum(1,1,current_spin,ipert), dpsi)
           END IF
           ! on perturbations
        enddo
        ! on k-points
     enddo
#ifdef __PARA
     !
     !  The calculation of dbecsum is distributed across processors (see addusdbec)
     !  Sum over processors the contributions coming from each slice of bands
     !
     IF (noncolin) THEN
        call mp_sum ( dbecsum_nc, intra_pool_comm )
     ELSE
        call mp_sum ( dbecsum, intra_pool_comm )
     ENDIF
#endif

     if (doublegrid) then
        do is = 1, nspin_mag
           do ipert = 1, npe
              call cinterpolate (drhoscfh(1,is,ipert), drhoscf(1,is,ipert), 1)
           enddo
        enddo
     else
        call zcopy (npe*nspin_mag*nrxx, drhoscf, 1, drhoscfh, 1)
     endif
     !
     !  In the noncolinear, spin-orbit case rotate dbecsum
     !
     IF (noncolin.and.okvan) CALL set_dbecsum_nc(dbecsum_nc, dbecsum, npe)
     !
     !    Now we compute for all perturbations the total charge and potential
     !
     call addusddens (drhoscfh, dbecsum, imode0, npe, 0)
#ifdef __PARA
     !
     !   Reduce the delta rho across pools
     !
     call mp_sum ( drhoscf, inter_pool_comm )
     call mp_sum ( drhoscfh, inter_pool_comm )
     IF (okpaw) call mp_sum ( dbecsum, inter_pool_comm )
#endif

     !
     ! q=0 in metallic case deserve special care (e_Fermi can shift)
     !

     IF (okpaw) THEN
        IF (lmetq0) &
           call ef_shift_paw (drhoscfh, dbecsum, ldos, ldoss, becsum1, &
                                                  dos_ef, irr, npe, .false.)
        DO ipert=1,npe
           dbecsum(:,:,:,ipert)=2.0_DP *dbecsum(:,:,:,ipert) &
                               +becsumort(:,:,:,imode0+ipert)
        ENDDO
     ELSE
        IF (lmetq0) call ef_shift(drhoscfh,ldos,ldoss,dos_ef,irr,npe,.false.)
     ENDIF
     !
     !   After the loop over the perturbations we have the linear change
     !   in the charge density for each mode of this representation.
     !   Here we symmetrize them ...
     !
     IF (.not.lgamma_gamma) THEN
#ifdef __PARA
        call psymdvscf (npe, irr, drhoscfh)
        IF ( noncolin.and.domag ) &
           CALL psym_dmag( npe, irr, drhoscfh)
#else
        call symdvscf (npe, irr, drhoscfh)
        IF ( noncolin.and.domag ) CALL sym_dmag( npe, irr, drhoscfh)
#endif
        IF (okpaw) THEN
           IF (minus_q) CALL PAW_dumqsymmetrize(dbecsum,npe,irr, &
                             npertx,irotmq,rtau,xq,tmq)
           CALL  &
              PAW_dusymmetrize(dbecsum,npe,irr,npertx,nsymq,irgq,rtau,xq,t)
        END IF
     ENDIF
     !
     !   ... save them on disk and
     !   compute the corresponding change in scf potential
     !
     do ipert = 1, npe
        if (fildrho.ne.' ') call davcio_drho (drhoscfh(1,1,ipert), lrdrho, &
                                              iudrho, imode0+ipert, +1)
        call zcopy (nrxx*nspin_mag,drhoscfh(1,1,ipert),1,dvscfout(1,1,ipert),1)
        call dv_of_drho (imode0+ipert, dvscfout(1,1,ipert), .true.)
     enddo
     !
     !   And we mix with the old potential
     !
     IF (okpaw) THEN
     !
     !  In this case we mix also dbecsum
     !
        call setmixout(npe*nrxx*nspin_mag,(nhm*(nhm+1)*nat*nspin_mag*npe)/2, &
                    mixout, dvscfout, dbecsum, ndim, -1 )
        call mix_potential (2*npe*nrxx*nspin_mag+2*ndim, &
                         mixout, mixin, &
                         alpha_mix(kter), dr2, npe*tr2_ph/npol, iter, &
                         nmix_ph, flmixdpot, convt)
        call setmixout(npe*nrxx*nspin_mag,(nhm*(nhm+1)*nat*nspin_mag*npe)/2, &
                       mixin, dvscfin, dbecsum, ndim, 1 )
        if (lmetq0.and.convt) &
           call ef_shift_paw (drhoscf, dbecsum, ldos, ldoss, becsum1, &
                                                  dos_ef, irr, npe, .true.)
     ELSE
        call mix_potential (2*npe*nrxx*nspin_mag, dvscfout, dvscfin, &
                         alpha_mix(kter), dr2, npe*tr2_ph/npol, iter, &
                         nmix_ph, flmixdpot, convt)
        if (lmetq0.and.convt) &
            call ef_shift (drhoscf, ldos, ldoss, dos_ef, irr, npe, .true.)
     ENDIF

     if (doublegrid) then
        do ipert = 1, npe
           do is = 1, nspin_mag
              call cinterpolate (dvscfin(1,is,ipert), dvscfins(1,is,ipert), -1)
           enddo
        enddo
     endif
!
!   calculate here the change of the D1-~D1 coefficients due to the phonon
!   perturbation
!
     IF (okpaw) CALL PAW_dpotential(dbecsum,rho%bec,int3_paw,npe)
     !
     !     with the new change of the potential we compute the integrals
     !     of the change of potential and Q
     !
     call newdq (dvscfin, npe)
#ifdef __PARA
     aux_avg (1) = DBLE (ltaver)
     aux_avg (2) = DBLE (lintercall)
     call mp_sum ( aux_avg, inter_pool_comm )
     averlt = aux_avg (1) / aux_avg (2)
#else
     averlt = DBLE (ltaver) / lintercall
#endif
     tcpu = get_clock ('PHONON')

     WRITE( stdout, '(/,5x," iter # ",i3," total cpu time :",f8.1, &
          &      " secs   av.it.: ",f5.1)') iter, tcpu, averlt
     dr2 = dr2 / npe
     WRITE( stdout, '(5x," thresh=",e10.3, " alpha_mix = ",f6.3, &
          &      " |ddv_scf|^2 = ",e10.3 )') thresh, alpha_mix (kter) , dr2
     !
     !    Here we save the information for recovering the run from this poin
     !
     CALL flush_unit( stdout )
     !
     rec_code=10
     IF (okpaw) THEN
        CALL write_rec('solve_lint', irr, dr2, iter, convt, npe, &
                                               dvscfin, drhoscfh, dbecsum)
     ELSE
        CALL write_rec('solve_lint', irr, dr2, iter, convt, npe, &
                                               dvscfin, drhoscfh)
     ENDIF

     if (check_stop_now()) call stop_smoothly_ph (.false.)
     if (convt) goto 155
  enddo
155 iter0=0
  !
  !    A part of the dynamical matrix requires the integral of
  !    the self consistent change of the potential and the variation of
  !    the charge due to the displacement of the atoms.
  !    We compute it here.
  !
  if (convt) then
     call drhodvus (irr, imode0, dvscfin, npe)
     if (fildvscf.ne.' ') then
        do ipert = 1, npe
           call davcio_drho ( dvscfin(1,1,ipert),  lrdrho, iudvscf, &
                         imode0 + ipert, +1 )
        end do
        if (elph) call elphel (npe, imode0, dvscfins)
     end if
  endif
  if (convt.and.nlcc_any) call addnlcc (imode0, drhoscfh, npe)
  if (lmetq0) deallocate (ldoss)
  if (lmetq0) deallocate (ldos)
  deallocate (h_diag)
  deallocate (aux1)
  deallocate (dbecsum)
  IF (okpaw) THEN
     if (lmetq0.and.allocated(becsum1)) deallocate (becsum1)
     deallocate (mixin)
     deallocate (mixout)
  ENDIF
  IF (noncolin) deallocate (dbecsum_nc)
  deallocate (dvscfout)
  deallocate (drhoscfh)
  if (doublegrid) deallocate (dvscfins)
  deallocate (dvscfin)

  call stop_clock ('solve_linter')
END SUBROUTINE solve_linter


SUBROUTINE setmixout(in1, in2, mix, dvscfout, dbecsum, ndim, flag )
USE kinds, ONLY : DP
USE mp_global, ONLY : intra_pool_comm
USE mp, ONLY : mp_sum
IMPLICIT NONE
INTEGER :: in1, in2, flag, ndim, startb, lastb
COMPLEX(DP) :: mix(in1+in2), dvscfout(in1), dbecsum(in2)

CALL divide (in2, startb, lastb)
ndim=lastb-startb+1

IF (flag==-1) THEN
   mix(1:in1)=dvscfout(1:in1)
   mix(in1+1:in1+ndim)=dbecsum(startb:lastb)
ELSE
   dvscfout(1:in1)=mix(1:in1)
   dbecsum=(0.0_DP,0.0_DP)
   dbecsum(startb:lastb)=mix(in1+1:in1+ndim)
#ifdef __PARA
   CALL mp_sum(dbecsum, intra_pool_comm)
#endif
ENDIF
END SUBROUTINE setmixout

