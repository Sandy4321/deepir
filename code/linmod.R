suppressMessages(library(textir))
suppressMessages(library(data.table))

## get results from w2v
w2vprob <- fread("data/yelpw2vprobs.csv", header=TRUE, verbose=FALSE)

## read the aggregated w2v vectors
aggvec <- read.table("data/yelp_vectors.txt", sep="|")

## read in the text
revs <- read.table("data/yelp_phrases.txt",
	sep="|",quote=NULL, comment="", 
	col.names=c("id","phrase","stars","sample"))

x <- sparseMatrix( 
			i=revs[,"id"]+1, j=as.numeric(revs[,"phrase"]), x=rep(1,nrow(revs)),
			dimnames=list(NULL, levels(revs[,"phrase"])),
            dims=c(nrow(aggvec), nlevels(revs[,"phrase"])) )
emptyrev <- which(rowSums(x)==0)

x <- x[-emptyrev,colSums(x>0)>5]
w2vprob <- as.matrix(w2vprob[-emptyrev,])
aggvec <- as.matrix(aggvec[-emptyrev,])

print(n <- nrow(x))

stars <- tapply(revs$stars, revs$id, mean)
samp <- tapply( revs$sample=="test", revs$id, mean)
test <- which(samp==1)

## read d2v
dv0train <- fread("data/yelpD2Vtrain0.csv", verbose=FALSE)
dv0test <- fread("data/yelpD2Vtest0.csv", verbose=FALSE)
dv1train <- fread("data/yelpD2Vtrain1.csv", verbose=FALSE)
dv1test <- fread("data/yelpD2Vtest1.csv", verbose=FALSE)
# all(dv0test[,id]==dv1test[,id])
# all(dv0test[,stars]==dv1test[,stars])
vecvar <- paste("x",1:100,sep="")
dv0x <- rbind(as.matrix(dv0train[,vecvar,with=FALSE]),
            as.matrix(dv0test[,vecvar,with=FALSE]))
dv1x <- rbind(as.matrix(dv1train[,vecvar,with=FALSE]),
            as.matrix(dv1test[,vecvar,with=FALSE]))
dvx <- cbind(dv0x,dv1x)
dvstars <- c(dv0train[,stars], dv0test[,stars])
dvtest <- nrow(dv0train)+1:nrow(dv0test)

library(parallel)
cl <- makeCluster(6, type="FORK")

geterr <- function(phat, y, PY=FALSE){
    if(ncol(phat)==1) phat <- cbind(1-phat,phat)
    y <- factor(y)
    yhat <- factor(levels(y)[apply(phat,1,which.max)])
    cat("mcr ")
    for(l in levels(y))
        cat(l, ":", round(
            mean(yhat[y==l] != y[y==l]),3), ", ", sep="")
    overall <- mean(yhat !=y)
    diff <- mean( abs(as.numeric(yhat) - as.numeric(y)) )
    py <- phat[cbind(1:nrow(phat),y)]
    lp <- log(py)
    lp[lp < (-50)] <- -50
    dev <- mean(-2*lp)
    cat("\noverall:", round(overall,3), "diff:", round(diff,3), "deviance:", dev, "\n")
    if(PY) return(py)
    invisible()
} 

getpy <- function(fit, xx, y, testset, PY=FALSE){
    if(inherits(fit,"randomForest"))
        phat <- as.matrix(predict(fit, xx[testset,], type="prob"))
    else 
        phat <- predict(fit, xx[testset,], type="response")
    py <- geterr(phat, y[testset], PY=PY)
    if(PY) return(py) 
    invisible()
}

## define y
ycoarse <- as.numeric(stars>2)
ynnp <- cut(stars, c(0,2,3,5))
yfine <- factor(stars)
dvycoarse <- as.numeric(dvstars>2)
dvynnp <- cut(dvstars, c(0,2,3,5))
dvyfine <- factor(dvstars)

### W2V inversion
cat("\n**** W2V INVERSION ****\n")
nullprob <- as.numeric(table(stars[-test])/length(stars[-test]))

cat("** COARSE **\n")
w2vpcoarse <- cbind(rowSums(w2vprob[,1:2]),rowSums(w2vprob[,3:5]))
geterr(w2vpcoarse[test,], ycoarse[test])

cat("** NNP **\n")
w2vpnnp <- cbind(rowSums(w2vprob[,1:2]),
    rowSums(w2vprob[,3,drop=FALSE]),
    rowSums(w2vprob[,4:5,drop=FALSE]))
geterr(w2vpnnp[test,], ynnp[test])

cat("** FINE **\n")
geterr(w2vprob[test,], yfine[test])

### logit word-count prediction
cat("\n*** COUNTREG ***\n")

cat("** COARSE **\n")
logitcoarse <- gamlr(x[-test,], ycoarse[-test], 
                family="binomial", lmr=1e-3)
pycoarse <- getpy(logitcoarse, x, ycoarse, test, PY=TRUE)

png(file="paper/graphs/yelp_logistic.png", width=12,height=6, units="in", res=180)
plot(logitcoarse)
invisible(dev.off())

cat("** NNP **\n")
logitnnp <- dmr(cl=cl, x[-test,], ynnp[-test], lmr=1e-3)
pynnp <- getpy(logitnnp, x, ynnp, test, PY=TRUE)

cat("** FINE **\n")
logitfine <- dmr(cl=cl, x[-test,], yfine[-test], lmr=1e-3)
pyfine <- getpy(logitfine, x, yfine, test, PY=TRUE)

cat("\n*** W2V and COUNTREG NNP ***\n")
wx <- cBind(w2vprob,x)
combof <- dmr(cl,wx[-test,], ynnp[-test])
getpy(combof, wx, ynnp, test)

## D2V stuff
## all run at zero lambda; AICc selects most complex model anyways
cat("\n*** D2V ***\n")

cat("** COARSE\n")
cat("dm0 **\n")
dv0coarse <- gamlr(dv0x[-dvtest,], dvycoarse[-dvtest],
                family="binomial", lmr=1e-4)
getpy(dv0coarse, dv0x, dvycoarse, dvtest)
cat("dm1 **\n")
dv1coarse <- gamlr(dv1x[-dvtest,], dvycoarse[-dvtest],
                family="binomial", lmr=1e-4)
getpy(dv1coarse, dv1x, dvycoarse, dvtest)
cat("dm both **\n")
dvcoarse <- gamlr(dvx[-dvtest,], dvycoarse[-dvtest],
                family="binomial", lmr=1e-4)
pydvcoarse <- getpy(dvcoarse, dvx, dvycoarse, dvtest, PY=TRUE)

cat("** NNP\n")
cat("dm0 **\n")
dv0nnp <- dmr(cl, dv0x[-dvtest,], dvynnp[-dvtest], lmr=1e-4)
getpy(dv0nnp, dv0x, dvynnp, dvtest)
cat("dm1 **\n")
dv1nnp <- dmr(cl, dv1x[-dvtest,], dvynnp[-dvtest], lmr=1e-4)
getpy(dv1nnp, dv1x, dvynnp, dvtest)
cat("dm both **\n")
dvnnp <- dmr(cl, dvx[-dvtest,], dvynnp[-dvtest], lmr=1e-4)
pydvnnp <- getpy(dvnnp, dvx, dvynnp, dvtest, PY=TRUE)

cat("** FINE\n")
cat("dm0 **\n")
dv0fine <- dmr(cl, dv0x[-dvtest,], dvyfine[-dvtest], lmr=1e-4)
getpy(dv0fine, dv0x, dvyfine, dvtest)
cat("dm1 **\n")
dv1fine <- dmr(cl, dv1x[-dvtest,], dvyfine[-dvtest], lmr=1e-4)
getpy(dv1fine, dv1x, dvyfine, dvtest)
cat("dm both **\n")
dvfine <- dmr(cl, dvx[-dvtest,], dvyfine[-dvtest], lmr=1e-4)
pydvfine <- getpy(dvfine, dvx, dvyfine, dvtest, PY=TRUE)

# mnir
cat("\n*** MNIR ***\n")
vmat <- sparse.model.matrix(~stars + yfine-1)
mnir <- mnlm(cl=cl, vmat[-test,], x[-test,], verb=1, bins=5)
zir <- srproj(mnir, x, select=100)

cat("** COARSE **\n")
fwdcoarse <- gamlr(zir[-test,], ycoarse[-test], lmr=1e-4, family="binomial")
pymnircoarse <- getpy(fwdcoarse, zir, ycoarse, test, PY=TRUE)

cat("** NNP **\n")
fwdnnp <- dmr(cl, zir[-test,], ynnp[-test],  lmr=1e-4)
pymnirnnp <- getpy(fwdnnp, zir, ynnp, test, PY=TRUE)

cat("** FINE **\n")
fwdfine <- dmr(cl, zir[-test,], yfine[-test],  lmr=1e-4)
pymnirfine <- getpy(fwdfine, zir, yfine, test, PY=TRUE)

### Aggregate vector prediction
cat("\n*** W2V AGGREGATION ***\n")

cat("** COARSE **\n")
avc <- gamlr(aggvec[-test,], ycoarse[-test], 
            family="binomial", lambda.min.ratio=1e-3)
getpy(avc, aggvec, ycoarse, test)

cat("** NNP **\n")
avnnp <- dmr(cl=cl, aggvec[-test,], ynnp[-test], lmr=1e-3)
getpy(avnnp, aggvec, ynnp, test)

cat("** FINE **\n")
avfine <- dmr(cl=cl, aggvec[-test,], yfine[-test], lmr=1e-3)
getpy(avfine, aggvec, yfine, test)

save.image("linmod.rda", compress=FALSE)

### some plots
w2vpc <- w2vpcoarse[test,2]
pdf("paper/graphs/coarseprob.pdf", width=9, height=2.75)
par(mfrow=c(1,3),mai=c(.45,.45,.3,.2),omi=c(.15,.15,0,0))
hist(w2vpc[ycoarse[test]==0], col=rgb(1,0,0,1), breaks=10, freq=FALSE,
         xlab="", ylab="", xlim=c(0,1), ylim=c(0,8), main="word2vec inversion")
hist(w2vpc[ycoarse[test]==1], col=rgb(1,1,0,.7), breaks=10, freq=FALSE, add=TRUE)

hist(pycoarse[ycoarse[test]==0], col=rgb(1,0,0,1), breaks=10, freq=FALSE,
         xlab="", ylab="", xlim=c(0,1), ylim=c(0,8), main="phrase regression")
hist(pycoarse[ycoarse[test]==1], col=rgb(1,1,0,.7), breaks=10, freq=FALSE, add=TRUE)

hist(pydvcoarse[dvycoarse[dvtest]==0], col=rgb(1,0,0,1), breaks=10, freq=FALSE,
         xlab="", ylab="", xlim=c(0,1), ylim=c(0,8), main="doc2vec regression")
hist(pydvcoarse[dvycoarse[dvtest]==1], col=rgb(1,1,0,.7), breaks=10, freq=FALSE, add=TRUE)

# hist(pymnircoarse[ycoarse[test]==0], col=rgb(1,0,0,1), breaks=10, freq=FALSE,
#          xlab="", ylab="", xlim=c(0,1), ylim=c(0,8), main="mnir")
# hist(pymnircoarse[ycoarse[test]==1], col=rgb(1,1,0,.7), breaks=10, freq=FALSE, add=TRUE)

mtext(side=2, "density", outer=TRUE,cex=.9, font=3)
mtext(side=1, "probability positive", outer=TRUE, cex=.9, font=3)
dev.off()


pdf("paper/graphs/coarseprob_bystar.pdf", width=9, height=2.5)
par(mfrow=c(1,4),mai=c(.4,.4,.3,.2),omi=c(.2,.2,0,0))
boxplot( w2vpc ~ yfine[test], col=heat.colors(5), varwidth=TRUE, main="word2vec inversion")
boxplot( pycoarse ~ yfine[test], col=heat.colors(5), varwidth=TRUE, main="phrase regression")
boxplot( pydvcoarse ~ dvyfine[dvtest], col=heat.colors(5), varwidth=TRUE, main="doc2vec regression")
boxplot( pymnircoarse ~ yfine[test], col=heat.colors(5), varwidth=TRUE, main="mnir")
mtext(side=1, "stars", outer=TRUE,cex=1, font=3)
mtext(side=2, "probability positive", outer=TRUE,cex=1, font=3)
dev.off()

w2vpnnpy <- w2vpnnp[cbind(1:n,ynnp)]
pdf("paper/graphs/nnpprob.pdf", width=9, height=2.5)
par(mfrow=c(1,4),mai=c(.4,.4,.3,.2),omi=c(.2,.2,0,0))
boxplot( w2vpnnpy[test] ~ ynnp[test], col=c("red","grey","yellow"), varwidth=TRUE, ylim=c(0,1), main="word2vec inversion")
boxplot( pynnp~ ynnp[test], col=c("red","grey","yellow"), varwidth=TRUE, ylim=c(0,1), main="phrase regression")
boxplot( pydvnnp~ dvynnp[dvtest], col=c("red","grey","yellow"), varwidth=TRUE, ylim=c(0,1), main="doc2vec regression")
boxplot( pymnirnnp~ ynnp[test], col=c("red","grey","yellow"), varwidth=TRUE, ylim=c(0,1), main="mnir")
mtext(side=1, "stars", outer=TRUE,cex=.9, font=3)
mtext(side=2, "probability of true category", outer=TRUE,cex=.9, font=3)
dev.off()

w2vpy <- w2vprob[cbind(1:n,stars)]
pdf("paper/graphs/fineprob.pdf", width=9, height=2.5)
par(mfrow=c(1,4),mai=c(.4,.4,.3,.2),omi=c(.2,.2,0,0))
boxplot( w2vpy[test] ~ yfine[test], col=heat.colors(5), varwidth=TRUE, ylim=c(0,1), main="word2vec inversion")
boxplot( pyfine~ yfine[test], col=heat.colors(5), ylim=c(0,1), varwidth=TRUE, main="phrase regression")
boxplot( pydvfine~ dvyfine[dvtest], col=heat.colors(5), ylim=c(0,1), varwidth=TRUE, main="doc2vec regression")
boxplot( pymnirfine~ yfine[test], col=heat.colors(5), ylim=c(0,1), varwidth=TRUE, main="mnir")
mtext(side=1, "stars", outer=TRUE,cex=.9, font=3)
mtext(side=2, "probability of true stars", outer=TRUE,cex=.9, font=3)
dev.off()
