# UNH Cybersecurity Website

This is the primary website for the UNH Cybersecurity Club. Below are details on how to setup and edit the website.

## Prerequisites

- [Git](https://git-scm.com/) - Version control system
    - Linux: 
        - ```sudo apt install git```
        - ```sudo yum install git```
        - ```sudo dnf install git```12
    - Windows:
        - I recommend [Git Bash](https://git-scm.com/downloads/win)
        - You can also use normal WSL, and just install git
- [Ruby](https://www.ruby-lang.org/en/) - Used to run Jekyll site
    - I Recommend using [RVM](https://rvm.io/) to install Ruby
- [Jekyll](https://jekyllrb.com/) - Self-explanatory
    - With ruby run ```gem install jekyll```

## Setup Project
1. Install project dependencies:
    ```shell
    bundle install
    ```

2. Run project locally:
    ```shell
    bundle exec jekyll serve
    ```
    This should run the project at *localhost:4000*

## Project Structure


