sridge<-function(x,y,cualcv.S=5,numlam.S=30,niter.S=50,normin=0,denormout=0,alone=0,ncores=1){                 
#Solves n*s_n^2 +lam*||beta1||^2} = min. Adapted from Ricardo Maronna's original MATLAB code.
#INPUT
#cualcv.S: method for estimating prediction error. cualcv-fold cross-validation
#normin: normalize input data?. 0=no, default ; 1=yes
#denormout: denormalize output?. 0=no, default ; 1=yes
#alone: are you calculating the estimator for its sake only? 0=no, default ; 1=yes
#numlam.S: number of lambda values, default 30
#niter.S : number of maximum iterations of IWLS
#ncores : number of cores to use for parallel computations. Default is one core.
#OUTPUT
#coef: (p+1)-vector of regression parameters, beta(1)=intercept
#scale: M-estimate of scale of the final regression estimate
#edf: final equivalent degrees of freedom
#lamda: optimal lambda
#delta: optimal delta


###Center and scale covariates and response using median and mad
if (normin==1){
prep<-prepara(x,y)
Xnor<-prep$Xnor
ynor<-prep$ynor
mux<-prep$mux
sigx<-prep$sigx
muy<-prep$muy
}else{
  Xnor<-x
  ynor<-y
}

#Spherical Principal Components (no centering)
#privar, Beig= vector of robust "eigenvalues" and matrix of eigenvectors
#Xnor is now = PCA scores
pca<-SPCC(Xnor)
privar<-pca$lamda
Beig<-pca$b
Xnor<-pca$scores
n<-nrow(Xnor)
p<-ncol(Xnor)
nkeep<-5 #number of candidates to be kept for full iteration in the Pena-Yohai procedure
privar<-privar*n #Makes the robust eigenvalues of the same order as those of classical PCA used for LS
nlam<-min(c(p,numlam.S))
pmax<-min(c(p, n/2))   #edf<=n/2 to keep BDP >=0.25
pp<-seq(1,pmax,length=nlam)
lamdas<-findlam(privar,pp) #find lambdas corresponding to the edf's
deltas<-0.5*(1-(pp)/n)  #for the M-scale used with Penia-Yohai

###Reorder data for CV
srt<-sort.int(sample(1:n),index.return=TRUE)  #Random permutation
tt<-srt$x
orden<-srt$ix
Xnord<-Xnor[orden,]
ynord<-ynor[orden]
###

# if (alone==1){
#   ###Set-up cluster for parallel computations
#   cores<-min(detectCores(),ncores)
#   try(cl<-makeCluster(cores))
#   try(registerDoParallel(cl))
#   ###
# }

###Parallel CV
exp.se<-c('CVSE')
klam<-NULL
mse<-foreach(klam=1:length(lamdas),.combine=c,.packages=c('mmlasso'),.export=exp.se)%do%{
      CVSE(Xnord,ynord,nfold=cualcv.S,lamdas[klam],pp[klam],nkeep,niter.S)
  }

if(any(is.infinite(mse))){
  warning('IWLS for S-Ridge failed when lambda equaled:')
  print(lamdas[which(is.infinite(mse))])
}
indmin<-which.min(mse)
lamin<-lamdas[indmin]
delmin<-deltas[indmin]
###

# if(alone==1){
#   stopCluster(cl)
# }

fin<-rr_se(Xnor,ynor,lamin,deltaesc=delmin,cc_scale=1,nkeep,niter.S,epsilon=1e-4)
beta<-fin$coef
betaslo<-beta[2:(length(beta))]
bint<-beta[1]
res<-ynor-Xnor%*%betaslo-as.vector(bint)
edf<-fin$edf
deltult<-0.5*(1-(edf+1)/n)#"delta" for final scale
deltult<-max(c(deltult, 0.25))
#c0: constant for consistency of final scale
c0<-const_marina(deltult)
sigma<-Mscale_mar(res,deltult,c0)   
a_cor<-mean(psi_marina(res/sigma,c0)^2)
b_cor<-mean(Mchi(res/sigma,c0,'bisquare',2))
c_cor<-mean(psi_marina(res/sigma,c0)*(res/sigma))
corr<-1+(edf+1)/(2*n)*(a_cor/(b_cor*c_cor))
fscale<-sigma*corr  #bias correction for final scale
#Back from PC to ordinary coordinates
betaslo<-Beig%*%betaslo

#De-normalize beta if required by user
if (normin==1 & denormout==1){
  betaslo<-betaslo/sigx
  bint<-muy+bint-mux%*%betaslo
}
beta<-c(bint,betaslo)
re<-list(coef=beta,scale=fscale,edf=edf,lamda=lamin,delta=delmin)
return(re)
}


CVSE<-function(X,y,nfold,lam,gradlib,nkeep,niter.S){
  #Performs nfold-CV for S-Ridge
  #INPUT
  #beta.ini, scale.ini: initial estimates of regression and scale
  #X,y: data
  #lam: penalization parameter
  #gradlib: degrees of freedom, used to calculate the delta for the M-scale
  #nkeep: number of candidates for full iterations of IWLS
  #niter.S : number of maximum iterations of IWLS
  #OUTPUT
  #mse: resulting MSE (estimated using a tau-scale)
  
  ###Segment data
  n<-nrow(X)
  p<-ncol(X)
  indin<-1:n
  nestim<-n*(1-1/nfold)
  lamcv<-lam
  deltaesc<-0.5*(1-(gradlib)/nestim)
  inint<-floor(seq(0,n,length.out=nfold+1))
  resid<-vector(mode='numeric',length=n)
  ###
  
  for (kk in 1:nfold){
    testk<-(inint[kk]+1):inint[kk+1]
    estik<-setdiff(indin,testk);
    Xtest<-X[testk,]
    Xesti<-X[estik,]
    ytest<-y[testk]
    yesti<-y[estik]
    se<-try(rr_se(Xesti,yesti,lamcv,deltaesc,cc_scale=1,nkeep,niter.S,epsilon=1e-4))
    if (class(se)=="try-error"){
      return(Inf)
    }
    bet<-se$coef
    bint<-bet[1]
    beta<-bet[2:(p+1)]
    fitk<-Xtest%*%beta+bint
    resid[testk]<-ytest-fitk
  }
  mse<-scale_tau(resid)
  return(mse)
}

findlam<-function(vals,r){
  #Finds lamdas which yield edf=r
  p<-length(vals)
  nr<-length(r)
  lamr<-vector(mode='numeric',nr);
  lam1<-0
  lam2<-max(vals)*(p/r-1)
  for (i in 1:nr){
    lam0<-c(lam1, lam2[i]+0.5)   #the value 0.5 is for lam=0
    lamr[i]<-uniroot(sumrat,lam0,vals,r[i])$root
  }
  return(lamr)
}

sumrat<-function(lam,vals,r){
  susu<-sum(vals/(vals+lam))-r
  return(susu)
}


const_marina<-function(delta){
  integrand<- function(x,c){dnorm(x)*rho_marina(x,c)}
  expe<-function(c,delta){integrate(integrand,lower=-Inf,upper=Inf,c)$value-delta}
  init<-c(0.1,100)
  try(cw<-uniroot(expe,init,delta)$root,silent=TRUE)
  if (class(cw)=="try-error"){
    warning("Something's wrong, could not find tuning constant for the scale")
    return(NULL)
  }
  return(cw)
}
