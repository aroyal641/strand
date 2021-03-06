#' Cut Data
#' @import data.table
#' @export
sr_cut <- function(variable, ...) UseMethod('sr_cut')

#' Cut Numeric
#' @import data.table
#' @export
sr_cut.numeric <- function(variable, k){
  breaksV <- quantile(variable,
                      probs = (0 : k) / k)
  labelsV <- vapply(1:(length(breaksV) - 1),
                    function(x) paste0(breaksV[x], ' : ', breaksV[x + 1]),
                    FUN.VALUE = character(1))
  cut(variable,
      breaks = breaksV,
      labels = labelsV,
      include.lowest = TRUE)
}

#' Cut Character
#' @import data.table
#' @export
sr_cut.character <- function(variable, ...){
  as.factor(variable)
}

#' Cut Factor
#' @import data.table
#' @export
sr_cut.factor <- function(variable, ...){
  variable
}

#' Stratify
#' @import data.table
#' @export
sr_stratify <- function(dat, id, variables, k = 4){
  dat <- as.list(copy(dat))
  if(length(k) == 1){
    k <- setNames(rep(k, length(variables)), variables)
  } else{
    msngVar <- setdiff(variables, names(k))
    kAppend <- setNames(rep(4, length(msngVar)), msngVar)
    k <- c(k, kAppend)
  }
  dat <- c(setNames(list(dat[[id]]), id),
           lapply(setNames(variables, variables),
                  function(v) sr_cut(dat[[v]], k = k[v])
           )
  )
  dat <- as.data.table(dat)
  dat[, stratum:= .GRP, by = variables]
  dat[, count:= .N, by = .(stratum)]
  setcolorder(dat, c(id, 'stratum', 'count'))

  stratumV <- setNames(unique(dat$stratum), unique(dat$stratum))

  structure(list(ids = dat[, c(id, 'stratum'), with = FALSE],
                 strata = unique(dat[, setdiff(names(dat), id), with = FALSE]),
                 levels = lapply(as.list(dat)[variables], levels)),
            class = c('strata', 'list'))
}

#' Assign Treatment
#' @import data.table
#' @export
sr_treat <- function(x, rate = 0.5, seed = NULL){
  strataDT <- copy(x$strata)
  idDT <- copy(x$ids)
  strataV <- unique(strataDT$stratum)

  if(!is.null(seed)){
    set.seed(seed = seed)
    seedV <- setNames(sample(strataV), strataV)
    strataDT[, seed:= seedV[stratum]]
  }

  for(s in strataV){
    s_count <- strataDT[stratum == s, count]
    stratum_assign = rep('Control', s_count)
    if(!is.null(seed)) set.seed(seed = strataDT[stratum == s, seed])
    stratum_assign[sample(1:s_count, round(rate * s_count), replace = FALSE)] = 'Treated'
    idDT[stratum == s, treatment:= stratum_assign]
  }
  idDT
}

#' Plot Quantiles
#' @import data.table
#' @import ggplot2
#' @export
sr_qplot <- function(x, selected = NULL){
  if(is.null(selected)) selected <- unique(x$strata$stratum)
  strata <- copy(x$strata[stratum %in% selected, ])
  strata <- melt(strata, id.vars = c('stratum', 'count'))
  strata <- strata[, list(count = sum(count)), by = c('variable', 'value')]
  strata[, value:= factor(value, levels = unlist(x$levels))]

  ggplot(data = strata, aes(x = value, y = count)) +
    theme(axis.text = element_text(angle = 45, color = 'black')) +
    geom_bar(stat = 'identity', fill = 'lightblue') +
    facet_wrap(~variable, scales = 'free')
}

#' Grid Search Strata
#' @import data.table
#' @export
sr_gridsearch <- function(dat, id, variables){
  dat <- as.data.frame(copy(dat))
  nvars <- variables[sapply(dat[, variables], is.numeric)]
  cvars <- setdiff(variables, nvars)
  kgrid <- expand.grid(
    setNames(lapply(nvars, function(x) 2:10), nvars)
  )
  kgrid <- as.data.table(kgrid)
  kgrid[, (cvars):= 1]

  kgrid$minsize <- unlist(
    lapply(1:nrow(kgrid),
           function(rownum) sr_minStratSize(x = rownum,
                                            kgrid = kgrid,
                                            dat = dat,
                                            id = id,
                                            variables = variables))
  )
  kgrid
}

#' Return Min. Stratum Size
#' @import data.table
#' @export
sr_minStratSize <- function(x, kgrid, dat, id, variables){
  tryCatch({
    strObj <- sr_stratify(dat = dat,
                          id = id,
                          variables = variables,
                          k = setNames(as.numeric(kgrid[x]), names(kgrid)))
    min(strObj$strata$count, na.rm = TRUE)
  }, error = function(x){
    return(NA)
  })
}

#' Print Strata
#' @import data.table
#' @export
print.strata <- function(x){
  cat(
    length(x$strata$stratum), 'Strata \n',
    length(x$levels), 'Variables \n',
    'Levels: \n',
    paste0(
      sapply(names(x$levels), function(l) paste0(l, ': ', length(x$levels[[l]]))),
      collapse = ', '
      ),
    '\n'
  )
}

#' Summarize Strata
#' @import data.table
#' @export
summary.strata <- function(x){
  summary(x$strata)
}


#' Search for PS Feature
#' @import data.table
#' @export
sr_feature_search <- function(dat,
                              form,
                              features,
                              ll_ratio_min = 1)
{
  if(length(features) < 1) return(list(form = form, last_ll = NULL))
  mfit <- glm(formula = form, family = 'binomial', data = dat)
  base_ll <- logLik(mfit)[1]
  names(features) <- features
  ll_ratio <- sapply(features, function(variable){
    new_form <- paste0(form, '+', variable)
    mfit <- glm(formula = new_form, family = 'binomial', data = dat)
    -2 * (base_ll[1] - logLik(mfit)[1])
  })
  if(max(ll_ratio) < ll_ratio_min){
    return(list(form = form,
                features = strsplit(strsplit(form, '~ ')[[1]][2], '\\+')[[1]]))

  }
  new_term <- names(ll_ratio)[which.max(ll_ratio)]
  form <- paste0(form, '+', new_term)
  sr_feature_search(dat = dat,
                    form = form,
                    features = setdiff(features, new_term),
                    ll_ratio_min = ll_ratio_min)

}

#' Imbens-Rubin Propensity Score
#' @import data.table
#' @export
sr_pscore <- function(dat,
                      primary,
                      secondary,
                      id_var,
                      min_ratios = c('lin' = 2.71, 'quad' = 2.71))
{
  dat <- copy(dat)
  lin_model <- sr_feature_search(dat = dat,
                                 form = paste0('treated ~ ', paste0(primary, collapse = '+')),
                                 features = secondary,
                                 ll_ratio_min = min_ratios['lin'])
  quad_terms <- character(0L)
  for(i in 1:length(lin_model$features)){
    quad_terms <- c(quad_terms,
                    paste0(lin_model$features[i], '*', lin_model$features[i:length(lin_model$features)]))
  }
  quad_model <- sr_feature_search(dat = dat,
                                  form = lin_model$form,
                                  features = quad_terms,
                                  ll_ratio_min = min_ratios['quad'])
  mfit <- glm(formula = quad_model$form, data = dat, family = 'binomial')
  dat[, pscore:= predict(mfit, dat, type = 'response')]

  list(mod = mfit,
       pscores = setNames(dat$pscore, dat[[id_var]]))
}

#' Inexact Sequential Matching
#' @import data.table
#' @import distances
#' @export
sr_match <- function(dat,
                     d_vars,
                     id_var,
                     treat_var,
                     pscores,
                     trim = c('min' = 0, 'max' = 1),
                     mahalanobis = TRUE)
{
  dat <- copy(dat)
  cdf <- ecdf(pscores)
  untrimmed <- list(min = min(pscores), max = max(pscores), N = length(pscores))
  pscores <- pscores[cdf(pscores) > trim['min'] & cdf(pscores) < trim['max']]
  trimmed <- list(min = min(pscores), max = max(pscores), N = length(pscores))
  if(trim['min'] != 0 & trim['max'] != 1){
    cat(sprintf('%s observations trimmed. \n P. Score Range changed from [%s, %s] to [%s, %s] \n',
                untrimmed$N - trimmed$N, untrimmed$min, untrimmed$max, trimmed$min, trimmed$max))
  }
  ids = names(sort(pscores, decreasing = TRUE))
  ids_treat = ids[ids %in% dat[get(treat_var) == 1][[id_var]]]
  ids_comp = ids[ids %in% dat[get(treat_var) == 0][[id_var]]]
  id_rowDict <- setNames(rownames(dat), dat[[id_var]])
  method = 'mahalanobize'
  if(!mahalanobis) method = NULL

  dstObj <- distances(data = dat[, .SD, .SDcols = c(id_var, d_vars)],
                      id_variable = id_var,
                      normalize = method)
  matchDT <- data.table(id = ids_treat, match = as.character(NA))
  for(i in ids_treat){
    distM = distance_columns(dstObj, as.numeric(id_rowDict[i]))
    distM = distM[!(rownames(distM) %in% c(na.omit(matchDT$match), ids_treat)), ]
    matchDT[id == i, match:= names(distM[which.min(distM)])]
  }
  setNames(matchDT$match, matchDT$id)
}

