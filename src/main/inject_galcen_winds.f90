!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2017 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://users.monash.edu.au/~dprice/phantom                               !
!--------------------------------------------------------------------------!
!+
!  MODULE: inject
!
!  DESCRIPTION:
!   Wind injection from galactic centre stars
!   Written by Daniel Price and Jorge Cuadra
!
!  REFERENCES: Cuadra et al. (2008), MNRAS 383, 458
!
!  OWNER: Daniel Price
!
!  $Id$
!
!  RUNTIME PARAMETERS:
!    datafile       -- name of data file for wind injection
!    outer_boundary -- kill gas particles outside this radius
!
!  DEPENDENCIES: dim, eos, infile_utils, io, part, partinject, physcon,
!    random, setbinary, units
!+
!--------------------------------------------------------------------------
module inject
 use dim,  only:maxptmass
 use part, only:nptmass
 implicit none
 character(len=*), parameter, public :: inject_type = 'galcen_winds'

 public :: inject_particles, write_options_inject, read_options_inject

 !integer :: wind_type = 1
 real :: outer_boundary = 20.
 character(len=120) :: datafile = 'winddata.txt'

 ! enumerated type for wind properties
 integer, parameter :: n_wind_prop = 2
 integer, parameter :: i_vel   = 1, &
                       i_Mdot  = 2

 ! array containing properties of the wind from each star
 real,    private :: wind(n_wind_prop,maxptmass)
 integer, private :: iseed = -666

contains

!-----------------------------------------------------------------------
!+
!  Main routine handling injection at the L1 point.
!+
!-----------------------------------------------------------------------
subroutine inject_particles(time,dtlast,xyzh,vxyzu,xyzmh_ptmass,vxyz_ptmass, &
           npart,npartoftype)
 use io,        only:fatal,iverbose
 use part,      only:massoftype,igas,ihacc,i_tlast
 use partinject,only:add_or_update_particle
 use setbinary, only:L1_point
 use physcon,   only:pi,solarm,seconds,years,km,kb_on_mH
 use units,     only:umass,udist,utime,unit_velocity
 use random,    only:ran2
 use eos,       only:gmw,gamma
 real,    intent(in)    :: time, dtlast
 real,    intent(inout) :: xyzh(:,:), vxyzu(:,:), xyzmh_ptmass(:,:), vxyz_ptmass(:,:)
 integer, intent(inout) :: npart
 integer, intent(inout) :: npartoftype(:)
 real :: r2,Mcut,Mdot_fac,vel_fac,Minject,Mdot_code,tlast
 real :: xyzi(3),vxyz(3),xyz_star(3),vxyz_star(3),dir(3)
 real :: rr,phi,theta,cosphi,sinphi,costheta,sintheta
 real :: deltat,h,u,vinject,temp_inject,uu_inject,gam1
 integer :: i,j,k,nskip,i_part,ninject
!
! kill particles outside some outer radius
!
 !$omp parallel do default(none) &
 !$omp shared(npart,xyzh,outer_boundary) &
 !$omp private(i,r2)
 do i=1,npart
    r2 = xyzh(1,i)**2 + xyzh(2,i)**2 + xyzh(3,i)**2
    if (r2 > outer_boundary**2) xyzh(4,i) = -abs(xyzh(4,i))
 enddo
 !$omp end parallel do

 Mcut = 1000.*(solarm/umass)
 nskip = 1
 do while(xyzmh_ptmass(4,nskip) > Mcut)
    nskip = nskip + 1
 enddo
 if (iverbose >= 2) print*,' skipping ',nskip,' point masses'
!
! convert mass loss rate from Msun/yr to code units
!
 Mdot_fac = (solarm/umass)*(utime/years)
 vel_fac  = (km/udist)*(utime/seconds)

 temp_inject = 1.e4
 gam1 = gamma - 1.
 if (gam1 <= 0) call fatal('inject','require gamma > 1 for wind injection')
!
! convert from temperature to thermal energy
! P/rho = kT/(mu m_H) = (gam-1)*u
!
 uu_inject = temp_inject * (((kb_on_mh) / unit_velocity)/unit_velocity) / (gmw*gam1)
 !print*,' uu_inject = ',uu_inject,kb_on_mh,unit_velocity,gmw,gam1
!
! loop over all wind particles
!
 !!$omp parallel do default(none) &
 !!$omp shared(nptmass)
 do i=nskip+1,nptmass
    !
    ! extract current position, velocity and injection radius of star
    !
    xyz_star  = xyzmh_ptmass(1:3,i)
    rr        = 1.0001*xyzmh_ptmass(ihacc,i)
    tlast     = xyzmh_ptmass(i_tlast,i)
    vxyz_star = vxyz_ptmass(1:3,i)

    !
    ! calculate how much mass to inject based on
    ! time interval since last injection
    !
    j = i - nskip ! position in wind table
    Mdot_code = wind(i_Mdot,j)*Mdot_fac
    vinject   = wind(i_vel,j)*vel_fac
    deltat    = time - tlast
    Minject   = Mdot_code*deltat
    !
    ! divide by mass of gas particles
    !
    ninject = int(Minject/massoftype(igas))
    if (iverbose >= 2) print*,' point mass ',i,j,' injecting ',ninject,Minject,massoftype(igas)

    !
    ! don't update tlast for a particular star unless that star injected
    !    particles this timestep; this way, fractional particles/timestep can 
    !    accumulate and eventually inject a particle, making Mdot more accurate
    !
    if(ninject > 0)
       do k=1,ninject
          !
          ! get random position on sphere
          !
          phi = 2.*pi*(ran2(iseed) - 0.5)
          theta = acos(2.*ran2(iseed) - 1.)
          sintheta = sin(theta)
          costheta = cos(theta)
          sinphi   = sin(phi)
          cosphi   = cos(phi)
          dir  = (/sintheta*cosphi,sintheta*sinphi,costheta/)

          xyzi = rr*dir + xyz_star
          vxyz = vinject*dir + vxyz_star
          !print*,' v = ',vinject,vxyz_star
          !print*,rr,vinject*deltat,100.*rr
          h = max(rr,10.*vinject*deltat) !/ninject**(1./3.)

          u = uu_inject

          i_part = npart + 1 ! all particles are new
          call add_or_update_particle(igas, xyzi, vxyz, h, u, i_part, npart, npartoftype, xyzh, vxyzu)
       enddo
       !
       ! update tlast to current time
       !
       xyzmh_ptmass(i_tlast,i) = time
    endif
 enddo
 if (iverbose >= 2) print*,'npart = ',npart

end subroutine inject_particles

!-----------------------------------------------------------------------
!+
!  Writes input options to the input file.
!+
!-----------------------------------------------------------------------
subroutine write_options_inject(iunit)
 use infile_utils, only:write_inopt
 integer, intent(in) :: iunit

 call write_inopt(trim(datafile),'datafile','name of data file for wind injection',iunit)
 call write_inopt(outer_boundary,'outer_boundary','kill gas particles outside this radius',iunit)
 !call write_inopt(wind_type,'wind_type','type of mass injection',iunit)

end subroutine write_options_inject

!-----------------------------------------------------------------------
!+
!  Reads input options from the input file.
!+
!-----------------------------------------------------------------------
subroutine read_options_inject(name,valstring,imatch,igotall,ierr)
 use io,      only:fatal,error,warning
 use physcon, only:solarm,years
 character(len=*), intent(in)  :: name,valstring
 logical,          intent(out) :: imatch,igotall
 integer,          intent(out) :: ierr
 integer, save :: ngot = 0
 character(len=30), parameter :: label = 'read_options_inject'
 integer :: nstars

 imatch  = .true.
 select case(trim(name))
 case('outer_boundary')
    read(valstring,*,iostat=ierr) outer_boundary
 case('datafile')
    read(valstring,*,iostat=ierr) datafile
    call read_wind_data(datafile,nstars)
    if (nstars /= nptmass) then
       call warning('read_options_inject','number of stars /= number of wind sources')
    endif
    ngot = ngot + 1
 case default
    imatch = .false.
 end select

 igotall = (ngot >= 1)

end subroutine read_options_inject

!-----------------------------------------------------------------------
!+
!  Reads wind input options from the input file.
!+
!-----------------------------------------------------------------------
subroutine read_wind_data(filename,nstars)
 use io, only:error
 character(len=*), intent(in)  :: filename
 integer,          intent(out) :: nstars
 integer :: iunit,ierr,idum,i

 nstars = 0
 wind = 0.
 open(newunit=iunit,file=trim(filename),status='old',action='read',iostat=ierr)
 do while(ierr == 0)
    nstars = nstars + 1
    if (nstars <= maxptmass) then
       read(iunit,*,iostat=ierr) idum,wind(i_vel,nstars),wind(i_Mdot,nstars)
       if (ierr /= 0) nstars = nstars - 1
    else
       call error('read_wind_data','array bounds exceeded')
    endif
 enddo

 if (nstars > 0) print "(1x,37('-'),/,1x,a,'|',2(a15,1x,'|'),/,1x,37('-'))",&
                        'ID',' Wind Vel(km/s)',' Mdot(Msun/yr)'
 do i=1,nstars
    print "(i3,'|',2(1pg15.4,1x,'|'))",i,wind(i_vel,i),wind(i_Mdot,i)
 enddo
 if (nstars > 0) print "(1x,37('-'))"

end subroutine read_wind_data

end module inject
