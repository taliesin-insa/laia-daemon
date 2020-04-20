#!/usr/bin/env Rscript
library(boot)
set.seed(12345)

# Global error rate: the sum of all errors divided among the sum of all tokens.
# Note: Expectes a matrix with n rows (sample size) and 2 columns.
#  - First column is the number of errors in data i
#  - Second column is the number of tokens in data i
err.global <- function(x) {
    return (sum(x[,1]) / sum(x[,2]) * 100)
}

# Mean error rate: the mean of the errors in each token divided by the number
# of tokens in that datum.
# Note: Expectes a matrix with n rows (sample size) and 2 columns.
#  - First column is the number of errors in data i
#  - Second column is the number of tokens in data i
err.mean <- function(x) {
    return (mean(x[,1] / x[,2]) * 100)
}

# Bootstrapping hypothesis testing
boot.test <-
    function(statistic, x, R, mu = 0, conf.level = 0.95,
             alternative = c('two.sided', 'less', 'greater'))
{
    alternative <- match.arg(alternative)
    if (!missing(mu) && (is.na(mu) || length(mu) != 1))
        stop("'mu' must be a single number")
    if(!missing(conf.level) &&
       (length(conf.level) != 1 || !is.finite(conf.level) ||
        conf.level < 0 || conf.level > 1))
        stop("'conf.level' must be a single number between 0 and 1")

    # Sample size
    n <- length(x)
    # Observed value of the statistic for the sample x
    obs <- statistic(x)

    # Empirical distribution of the statistic, using bootstrapping.
    empirical.distribution <- boot(
        data = x, R = R,
        statistic = function(data, indices) statistic(data[indices,]))

    # Empirical distribution of the statistic under the null hypothesis.
    empirical.distribution.h0 <- empirical.distribution$t - obs + mu
    xlim <- c(min(min(empirical.distribution.h0),
                  min(empirical.distribution$t)),
              max(max(empirical.distribution.h0),
                  max(empirical.distribution$t)))
    hist(empirical.distribution.h0, freq = FALSE, xlim = xlim, border = 2)
    hist(empirical.distribution$t,  freq = FALSE, xlim = xlim, border = 3,
         add = TRUE)

    # Compute p-values and confidence intervals.
    if (alternative == 'less') {
        pval <- (sum(obs >= empirical.distribution.h0) + 1) / (R + 1)
        cint <- c(-Inf, quantile(empirical.distribution$t, conf.level,
                                 names = FALSE))
    } else if (alternative == 'greater') {
        pval <- (sum(obs <= empirical.distribution.h0) + 1) / (R + 1)
        cint <- c(quantile(empirical.distribution$t, 1 - conf.level,
                           names = FALSE), Inf)
    } else {
        pval1 <- (sum(obs >= empirical.distribution.h0) + 1) / (R + 1)
        pval2 <- (sum(obs <= empirical.distribution.h0) + 1) / (R + 1)
        pval <- 2 * min(pval1, pval2)
        alpha <- 1 - conf.level / 2
        cint <- quantile(empirical.distribution$t, c(alpha, 1 - alpha),
                         names = FALSE)
    }

    return (list(statistic = obs,
                 estimate = mean(empirical.distribution$t),
                 p.value = pval,
                 null.value = mu,
                 alternative = alternative,
                 conf.int = cint,
                 R = R))
}

# Parse arguments
args <- commandArgs(trailingOnly=TRUE)
if(length(args) < 2) {
    stop('Provide the errors files, computed with utils/compute-errors.sh')
}

# Select which statisitic function are we going to use
statistic.function <- new.env()
statistic.function[['global']] <- err.global
statistic.function[['mean']] <- err.mean
statistic.name <- 'mean'
if (length(args) > 2) {
    if (args[3] != 'global' && args[3] != 'mean')
        stop("Choose the error rate statistic type: 'global' or 'mean'")
    statistic.name <- args[3]
}

# Margin of Equivalence/Non-inferiority
margin <- 0.0;
if(length(args) > 3) {
    margin <- as.numeric(args[4]);
}

# Read data
df1 <- read.table(args[1], header=FALSE)
df2 <- read.table(args[2], header=FALSE)

# Print statistics in each of the observed samples.
stat1 <- statistic.function[[statistic.name]](matrix(c(df1$V2, df1$V6),
                                   nrow = nrow(df1), ncol = 2))
cat(sprintf('Observed %s %%ERR for Method 1 = %.4f\n', statistic.name, stat1))

stat2 <- statistic.function[[statistic.name]](matrix(c(df2$V2, df2$V6),
                                   nrow = nrow(df2), ncol = 2))
cat(sprintf('Observed %s %%ERR for Method 2 = %.4f\n', statistic.name, stat2))

# Paired data
df <- merge(as.data.frame(df1), as.data.frame(df2), by = 'V1')
x  <- matrix(c(df$V2.x - df$V2.y, df$V6.x), nrow = nrow(df), ncol = 2)

# Print statistic of the difference
stat3 <- statistic.function[[statistic.name]](x)
cat(sprintf('Observed %s %%ERR1 - %%ERR2 = %.4f\n', statistic.name, stat3))
cat('\n')

tx <- (x[,1] / x[,2]) * 100

# Check normality of the differences in the mean error rates,
# check Rplots.pdf
qqnorm(tx)
qqline(tx)

cat('===============================================\n')
cat('=== TESTING EQUIVALENCE, H0 : %ERR1 = %ERR2 ===\n')
cat('===============================================\n\n')

if (statistic.name == 'mean') {
    cat('T-STUDENT TEST:\n')
    cat('===============\n')
    a <- t.test(tx, alternative = 'two.sided')
    cat(sprintf('Statistic = %f\n', a[['statistic']]))
    cat(sprintf('P-value = %f\n', a[['p.value']]))
    cat(sprintf('Estimate = %f [%f -- %f]\n\n',
                a[['estimate']], a[['conf.int']][1], a[['conf.int']][2]))
}

if (FALSE) {
if (statistic.name == 'mean') {
    cat('WILCOX TEST:\n')
    cat('============\n')
    b <- wilcox.test(tx, alternative = 'two.sided', conf.int = TRUE)
    cat(sprintf('Statistic = %f\n', b[['statistic']]))
    cat(sprintf('P-value = %f\n', b[['p.value']]))
    cat(sprintf('Estimate = %f [%f -- %f]\n\n',
                b[['estimate']], b[['conf.int']][1], b[['conf.int']][2]))
}

cat('BINOMIAL TEST:\n')
cat('==============\n')
c <- binom.test(sum(df1$V2), sum(df1$V6), stat2 / 100,
                alternative = 'two.sided')
cat(sprintf('Statistic = %f\n', c[['statistic']]))
cat(sprintf('P-value = %f\n', c[['p.value']]))
cat(sprintf('Estimate = %f [%f -- %f]\n\n',
            c[['estimate']], c[['conf.int']][1], c[['conf.int']][2]))
}

cat('BOOTSTRAPPING TEST:\n')
cat('===================\n')
d <- boot.test(statistic = statistic.function[[statistic.name]],
               x = x, R = 5000, alternative = 'two.sided')
cat(sprintf('Statistic = %f\n', d[['statistic']]))
cat(sprintf('P-value = %f\n', d[['p.value']]))
cat(sprintf('Estimate = %f [%f -- %f]\n\n',
            d[['estimate']], d[['conf.int']][1], d[['conf.int']][2]))

for (m in c(0.01, 0.05, 0.10, 0.15)) {
    cat('\n===========================================================\n')
    cat(sprintf(
        '=== TESTING NON-INFERIORITY, H0 : %%ERR1 >= %.2f * %%ERR2 ===\n',
        1 + m))
    cat('===========================================================\n\n')

    if (statistic.name == 'mean') {
        cat('T-STUDENT TEST:\n')
        cat('===============\n')
        a <- t.test(tx, mu = m * stat2, alternative = 'less')
        cat(sprintf('Statistic = %f\n', a[['statistic']]))
        cat(sprintf('P-value = %f\n', a[['p.value']]))
        cat(sprintf('Estimate = %f [%f -- %f]\n\n',
                    a[['estimate']], a[['conf.int']][1], a[['conf.int']][2]))
    }

    if (FALSE) {
    if (statistic.name == 'mean') {
        cat('WILCOX TEST:\n')
        cat('============\n')
        b <- wilcox.test(tx, mu = m * stat2, alternative = 'less',
                         conf.int = TRUE)
        cat(sprintf('Statistic = %f\n', b[['statistic']]))
        cat(sprintf('P-value = %f\n', b[['p.value']]))
        cat(sprintf('Estimate = %f [%f -- %f]\n\n',
                    b[['estimate']], b[['conf.int']][1], b[['conf.int']][2]))
    }

    cat('BINOMIAL TEST:\n')
    cat('==============\n')
    c <- binom.test(sum(df1$V2), sum(df1$V6), (stat2 + (1 + m)) / 100,
                        alternative = 'less')
    cat(sprintf('Statistic = %f\n', c[['statistic']]))
    cat(sprintf('P-value = %f\n', c[['p.value']]))
    cat(sprintf('Estimate = %f [%f -- %f]\n\n',
                c[['estimate']], c[['conf.int']][1], c[['conf.int']][2]))
    }

    cat('BOOTSTRAPPING TEST:\n')
    cat('===================\n')
    d <- boot.test(statistic = statistic.function[[statistic.name]],
                   mu = stat2 * m, x = x, R = 5000, alternative = 'less')
    cat(sprintf('Statistic = %f\n', d[['statistic']]))
    cat(sprintf('P-value = %f\n', d[['p.value']]))
    cat(sprintf('Estimate = %f [%f -- %f]\n\n',
                d[['estimate']], d[['conf.int']][1], d[['conf.int']][2]))
}
